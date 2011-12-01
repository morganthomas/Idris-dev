{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, DeriveFunctor,
             PatternGuards #-}

module Idris.REPL where

import Idris.AbsSyntax
import Idris.REPLParser
import Idris.ElabDecls
import Idris.ElabTerm
import Idris.Error
import Idris.Delaborate
import Idris.Compiler
import Idris.Prover
import Idris.Parser
import Paths_idris

import Core.Evaluate
import Core.ProofShell
import Core.TT
import Core.Constraints

import System.Console.Readline
import System.FilePath
import System.Environment
import System.Process
import System.Directory
import Control.Monad
import Control.Monad.State
import Data.List
import Data.Char
import Data.Version

repl :: IState -> [FilePath] -> Idris ()
repl orig mods
     = do let prompt = mkPrompt mods
          x <- lift $ readline (prompt ++ "> ")
          case x of
              Nothing -> do iputStrLn "Bye bye"
                            return ()
              Just input -> do lift $ addHistory input
                               ms <- processInput input orig mods
                               case ms of
                                    Just mods -> repl orig mods
                                    Nothing -> return ()

iucheck :: Idris ()
iucheck = do tit <- typeInType
             when (not tit) $
                do ist <- get
                   idrisCatch (tclift $ ucheck (idris_constraints ist))
                              (\e -> do let msg = report e
                                        setErrLine (getErrLine msg)
                                        iputStrLn msg)

mkPrompt [] = "Idris"
mkPrompt [x] = "*" ++ dropExtension x
mkPrompt (x:xs) = "*" ++ dropExtension x ++ " " ++ mkPrompt xs

processInput :: String -> IState -> [FilePath] -> Idris (Maybe [FilePath])
processInput cmd orig inputs
    = do i <- get
         let fn = case inputs of
                        (f:_) -> f
                        _ -> ""
         case parseCmd i cmd of
                Left err ->   do lift $ print err
                                 return (Just inputs)
                Right Reload -> do put (orig { idris_options = idris_options i })
                                   clearErr
                                   mods <- mapM loadModule inputs  
                                   return (Just inputs)
                Right Edit -> do edit fn orig
                                 return (Just inputs)
                Right AddProof -> do idrisCatch (addProof fn orig)
                                                (\e -> iputStrLn (report e))
                                     return (Just inputs)
                Right Quit -> do iputStrLn "Bye bye"
                                 return Nothing
                Right cmd  -> do idrisCatch (process cmd)
                                            (\e -> iputStrLn (report e))
                                 return (Just inputs)

edit :: FilePath -> IState -> Idris ()
edit "" orig = iputStrLn "Nothing to edit"
edit f orig
    = do i <- get
         env <- lift $ getEnvironment
         let editor = getEditor env
         let line = case errLine i of
                        Just l -> " +" ++ show l ++ " "
                        Nothing -> " "
         let cmd = editor ++ line ++ f
         lift $ system cmd
         clearErr
         put (orig { idris_options = idris_options i })
         loadModule f
         iucheck
         return ()
   where getEditor env | Just ed <- lookup "EDITOR" env = ed
                       | Just ed <- lookup "VISUAL" env = ed
                       | otherwise = "vi"

addProof :: FilePath -> IState -> Idris ()
addProof "" orig = iputStrLn "Nothing to add to"
addProof f orig
    = do let fb = f ++ "~"
         lift $ copyFile f fb -- make a backup in case something goes wrong!
         prog <- lift $ readFile fb
         i <- get
         case last_proof i of
            Nothing -> iputStrLn "No proof to add"
            Just (n, p) -> do let prog' = insertScript (showProof n p) (lines prog)
                              lift $ writeFile f (unlines prog')
                              iputStrLn $ "Added proof " ++ show n
                              put (i { last_proof = Nothing })
                              -- lift $ removeFile fb -- uncomment when less scared :)

insertScript :: String -> [String] -> [String]
insertScript prf [] = "\n---------- Proofs ----------" : "" : [prf]
insertScript prf (p@"---------- Proofs ----------" : "" : xs) 
    = p : "" : prf : xs
insertScript prf (x : xs) = x : insertScript prf xs

process :: Command -> Idris ()
process Help = iputStrLn displayHelp
process (Eval t) = do (tm, ty) <- elabVal toplevel False t
                      ctxt <- getContext
                      ist <- get 
                      let tm' = normaliseC ctxt [] tm
                      let ty' = normaliseC ctxt [] ty
                      logLvl 3 $ "Raw: " ++ show (tm', ty')
                      imp <- impShow
                      iputStrLn (showImp imp (delab ist tm') ++ " : " ++ 
                                 showImp imp (delab ist ty'))
process (Check (PRef _ n))
                  = do ctxt <- getContext
                       ist <- get
                       imp <- impShow
                       case lookupTy Nothing n ctxt of
                        [t] -> iputStrLn $ show n ++ " : " ++
                                  showImp imp (delab ist t)
                        _ -> iputStrLn $ "No such variable " ++ show n
process (Check t) = do (tm, ty) <- elabVal toplevel False t
                       ctxt <- getContext
                       ist <- get 
                       imp <- impShow
                       let ty' = normaliseC ctxt [] ty
                       iputStrLn (showImp imp (delab ist tm) ++ " : " ++ 
                                 showImp imp (delab ist ty))
process Universes = do i <- get
                       let cs = idris_constraints i
--                        iputStrLn $ showSep "\n" (map show cs)
                       lift $ print (map fst cs)
                       let n = length cs
                       iputStrLn $ "(" ++ show n ++ " constraints)"
                       case ucheck cs of
                            Error e -> iputStrLn $ pshow i e
                            OK _ -> iputStrLn "Universes OK"
process (Defn n) = do ctxt <- getContext
                      lift $ print (lookupDef Nothing n ctxt)
process (Spec t) = do (tm, ty) <- elabVal toplevel False t
                      ctxt <- getContext
                      ist <- get
                      let tm' = specialise ctxt (idris_statics ist) tm
                      iputStrLn (show (delab ist tm'))
process (Prove n) = prover n
process (HNF t)  = do (tm, ty) <- elabVal toplevel False t
                      ctxt <- getContext
                      ist <- get
                      let tm' = simplify ctxt [] tm
                      iputStrLn (show (delab ist tm'))
process TTShell  = do ist <- get
                      let shst = initState (tt_ctxt ist)
                      shst' <- lift $ runShell shst
                      return ()
process (Execute f) = do compile f 
                         lift $ system ("./" ++ f)
                         return ()
process (Compile f) = do compile f 
process (LogLvl i) = setLogLevel i 
process Metavars = do ist <- get
                      let mvs = idris_metavars ist \\ primDefs
                      case mvs of
                        [] -> iputStrLn "No global metavariables to solve"
                        _ -> iputStrLn $ "Global metavariables:\n\t" ++ show mvs
process NOP      = return ()

displayHelp = let vstr = showVersion version in
              "\nIdris version " ++ vstr ++ "\n" ++
              "--------------" ++ map (\x -> '-') vstr ++ "\n\n" ++
              concatMap cmdInfo help
  where cmdInfo (cmds, args, text) = "   " ++ col 16 12 (showSep " " cmds) args text 
        col c1 c2 l m r = 
            l ++ take (c1 - length l) (repeat ' ') ++ 
            m ++ take (c2 - length m) (repeat ' ') ++ r ++ "\n"

help =
  [ (["Command"], "Arguments", "Purpose"),
    ([""], "", ""),
    (["<expr>"], "", "Evaluate an expression"),
    ([":t"], "<expr>", "Check the type of an expression"),
    ([":r",":reload"], "", "Reload current file"),
    ([":e",":edit"], "", "Edit current file using $EDITOR or $VISUAL"),
    ([":m",":metavars"], "", "Show remaining proof obligations (metavariables)"),
    ([":p",":prove"], "<name>", "Prove a metavariable"),
    ([":a",":addproof"], "", "Add last proof to source file"),
    ([":c",":compile"], "<filename>", "Compile to an executable <filename>"),
    ([":exec",":execute"], "<filename>", "Compile to an executable <filename> and run"),
    ([":?",":h",":help"], "", "Display this help text"),
    ([":q",":quit"], "", "Exit the Idris system")
  ]

