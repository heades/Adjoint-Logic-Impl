{-# LANGUAGE FlexibleContexts #-}

module Repl where

import Control.Monad.State
import Control.Monad.Except
import System.Console.Haskeline
import System.Console.Haskeline.MonadException
import System.Exit
import Unbound.LocallyNameless.Subst
import Data.List.Split

import Syntax
import Parser
import Pretty
import Queue
import TypeCheck

type Qelm = (TmName, Term)
type REPLStateIO = StateT (Queue Qelm) IO

instance MonadException m => MonadException (StateT s m) where
    controlIO f = StateT $ \s -> controlIO $ \(RunIO run) -> let
                    run' = RunIO (fmap (StateT . const) . run . flip runStateT s)
                    in fmap (flip runStateT s) $ f run'

io :: IO a -> REPLStateIO a
io i = liftIO i

pop :: REPLStateIO (TmName, Term)
pop = get >>= return.headQ

push :: Qelm -> REPLStateIO ()
push t = get >>= put.(`snoc` t) 
         
unfoldDefsInTerm :: (Queue Qelm) -> Term -> Term
unfoldDefsInTerm q t =
    let uq = toListQ $ unfoldQueue q
     in substs uq t

unfoldQueue :: (Queue Qelm) -> (Queue Qelm)
unfoldQueue q = fixQ q emptyQ step
 where
   step e@(x,t) _ r = (mapQ (substDef x t) r) `snoc` e
    where
      substDef :: Name Term -> Term -> Qelm -> Qelm
      substDef x t (y, t') = (y, subst x t t')

searchTerm :: (Queue Qelm) -> TmName -> Term
searchTerm q tmn =
    case (searchTerm' q tmn) of
     -- Left lf -> Var (s2n lf) -- temporary solution for error handling
      Left lf -> error "Error, not in queue(2)." -- exception
      Right rt -> rt

searchTerm' :: (Queue Qelm) -> TmName -> Either String Term
searchTerm' q tmn =
   case (Prelude.lookup tmn l) of
   Just x -> Right x
   Nothing -> Left "Error, not in queue." 
   where
     l = toListQ $ unfoldQueue q

retrieveType :: Either TypeException Type -> Type
retrieveType (Right r) = r
retrieveType _ = undefined -- handle some errors

handleCMD :: String -> REPLStateIO()
handleCMD "" = return ()
handleCMD s =
    case (parseLine s) of
      Left msg -> io $ putStrLn msg
      Right l -> handleLine l
  where
    handleLine :: REPLExpr -> REPLStateIO()
    handleLine (Let x t) = push (x,t)
    handleLine (ShowAST t) = io.putStrLn.show $ t
    handleLine (Unfold t) = get >>= (
      \defs -> io.putStrLn.runPrettyTerm $ unfoldDefsInTerm defs t)
    handleLine (ReplType t) = get >>= (
      \defs -> io.putStrLn.runPrettyType $ retrieveType $
               constructType $ unfoldDefsInTerm defs t)
    handleLine (CallTerm t) = get >>= (
      \q -> io.putStrLn.runPrettyTerm $ searchTerm q t)
    handleLine DumpState = get >>= io.print.(mapQ prettyDef)
      where
        prettyDef (x, t) = "let " ++ (n2s x) ++ " = " ++ (runPrettyTerm t)
    
banner :: String
banner = "Welcome to ILL, an Intuitionistic Linear Logic programming language!\n\n"

helpDoc :: String
helpDoc =
 "\nCommands available for the ILL REPL\&:\n\n\
 \\&:u \&:unfold        -> Unfold and print definitions in queue.\n\
 \\&:s \&:show <term>   -> Print the abstract syntax of a term.\n\
 \\&:d \&:dump          -> Print contents of REPL queue.\n\
 \\&:h \&:help          -> Display this help document.\n"
  
main = do
    putStr banner
    evalStateT (runInputT defaultSettings loop) emptyQ
      where
         loop :: InputT REPLStateIO ()
         loop = do
                 minput <- getInputLine "ILL> "
                 case minput of
                     Nothing -> return ()
                     Just input | input == ":q" || input == ":quit" ->
                                  liftIO $ putStrLn "Exiting ILL." >> return ()
                                | input == ":h" || input == ":help" ->
                                  (liftIO $ putStrLn helpDoc) >> loop
                                | otherwise -> (lift.handleCMD $ input) >> loop
