{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{- |

Repline exposes an additional monad transformer on top of Haskeline called 'HaskelineT'. It simplifies several
aspects of composing Haskeline with State and Exception monads in modern versions of mtl.

> type Repl a = HaskelineT IO a

The evaluator 'evalRepl' evaluates a 'HaskelineT' monad transformer by constructing a shell with several
custom functions and evaluating it inside of IO:

  * Commands: Handled on ordinary input.

  * Completions: Handled when tab key is pressed.

  * Options: Handled when a command prefixed by a colon is entered.

  * Banner: Text Displayed at initialization.

  * Initializer: Run at initialization.

A simple evaluation function might simply echo the output back to the screen.

> -- Evaluation : handle each line user inputs
> cmd :: String -> Repl ()
> cmd input = liftIO $ print input

Several tab completion options are available, the most common is the 'WordCompleter' which completes on single
words separated by spaces from a list of matches. The internal logic can be whatever is required and can also
access a StateT instance to query application state.

> -- Tab Completion: return a completion for partial words entered
> completer :: Monad m => WordCompleter m
> completer n = do
>   let names = ["kirk", "spock", "mccoy"]
>   let matches = filter (isPrefixOf n) names
>   return $ map simpleCompletion matches

Input which is prefixed by a colon (commands like \":type\" and \":help\") queries an association list of
functions which map to custom logic. The function takes a space-separated list of augments in it's first
argument. If the entire line is desired then the 'unwords' function can be used to concatenate.

> -- Commands
> help :: [String] -> Repl ()
> help args = liftIO $ print $ "Help: " ++ show args
>
> say :: [String] -> Repl ()
> say args = do
>   _ <- liftIO $ system $ "cowsay" ++ " " ++ (unwords args)
>   return ()

Now we need only map these functions to their commands.

> options :: [(String, [String] -> Repl ())]
> options = [
>     ("help", help)  -- :help
>   , ("say", say)    -- :say
>   ]

The banner function is simply an IO action that is called at the start of the shell.

> ini :: Repl ()
> ini = liftIO $ putStrLn "Welcome!"

Putting it all together we have a little shell.

> main :: IO ()
> main = evalRepl ">>> " cmd options (Word completer) ini

Putting this in a file we can test out our cow-trek shell.

> $ runhaskell Main.hs
> Welcome!
> >>> <TAB>
> kirk spock mccoy
>
> >>> k<TAB>
> kirk
>
> >>> spam
> "spam"
>
> >>> :say Hello Haskell
>  _______________
> < Hello Haskell >
>  ---------------
>         \   ^__^
>          \  (oo)\_______
>             (__)\       )\/\
>                 ||----w |
>                 ||     ||

See <https://github.com/sdiehl/repline> for more examples.

-}

module System.Console.Repline (
  HaskelineT,
  runHaskelineT,

  Cmd,
  Options,
  WordCompleter,
  LineCompleter,
  CompleterStyle(..),
  Command,

  --ReplSettings(ReplSettings),
  --emptySettings,

  evalRepl,
  --evalReplWith,

  listFiles, -- re-export
  trimComplete,
) where

import System.Console.Haskeline.Completion
import System.Console.Haskeline.MonadException
import qualified System.Console.Haskeline as H

import Data.List (isPrefixOf)
import Control.Applicative
import Control.Monad.State.Strict

-------------------------------------------------------------------------------
-- Haskeline Transformer
-------------------------------------------------------------------------------

newtype HaskelineT (m :: * -> *) a = HaskelineT { unHaskeline :: H.InputT m a }
 deriving (Monad, Functor, Applicative, MonadIO, MonadException, MonadTrans, MonadHaskeline)

runHaskelineT :: MonadException m => H.Settings m -> HaskelineT m a -> m a
runHaskelineT s m = H.runInputT s (H.withInterrupt (unHaskeline m))

class MonadException m => MonadHaskeline m where
  getInputLine :: String -> m (Maybe String)
  getInputChar :: String -> m (Maybe Char)
  outputStr    :: String -> m ()
  outputStrLn  :: String -> m ()

instance MonadException m => MonadHaskeline (H.InputT m) where
  getInputLine = H.getInputLine
  getInputChar = H.getInputChar
  outputStr    = H.outputStr
  outputStrLn  = H.outputStrLn

instance MonadState s m => MonadState s (HaskelineT m) where
  get = lift get
  put = lift . put

instance (MonadHaskeline m) => MonadHaskeline (StateT s m) where
  getInputLine = lift . getInputLine
  getInputChar = lift . getInputChar
  outputStr    = lift . outputStr
  outputStrLn  = lift . outputStrLn

-------------------------------------------------------------------------------
-- Repl
-------------------------------------------------------------------------------

type Cmd m = [String] -> m ()
type Options m = [(String, Cmd m)]
type Command m = String -> m ()

type WordCompleter m = (String -> m [Completion])
type LineCompleter m = (String -> String -> m [Completion])

data ReplSettings m = ReplSettings
  { _cmd       :: Command (HaskelineT m) -- ^ Command function
  , _opts      :: Options (HaskelineT m) -- ^ Options map
  , _compstyle :: CompleterStyle m       -- ^ Internal completer function
  , _init      :: m ()                   -- ^ Initializer function.
  , _banner    :: String                 -- ^ Banner string
  }

emptySettings :: MonadHaskeline m => ReplSettings m
emptySettings = ReplSettings (const $ return ()) [] File (return ()) ""

-- | Wrap a HasklineT action so that if an interrupt is thrown the shell continues as normal.
tryAction :: MonadException m => HaskelineT m a -> HaskelineT m a
tryAction (HaskelineT f) = HaskelineT (H.withInterrupt loop)
    where loop = handle (\H.Interrupt -> loop) f

-- | Completion loop.
replLoop :: MonadException m
         => String
         -> Command (HaskelineT m)
         -> Options (HaskelineT m)
         -> HaskelineT m ()
replLoop banner cmdM opts = loop
  where
    loop = do
      minput <- H.handleInterrupt (return (Just "")) $ getInputLine banner
      case minput of
        Nothing -> outputStrLn "Goodbye."

        Just "" -> loop
        Just ":" -> loop

        Just (':' : cmds) -> do
          let (cmd:args) = words cmds
          optMatcher cmd opts args
          loop

        Just input -> do
          H.handleInterrupt (liftIO $ putStrLn "Ctrl-C") $ cmdM input
          loop

-- | Match the options.
optMatcher :: MonadHaskeline m => String -> Options m -> [String] -> m ()
optMatcher s [] _ = outputStrLn $ "No such command :" ++ s
optMatcher s ((x, m):xs) args
  | s `isPrefixOf` x = m args
  | otherwise = optMatcher s xs args

-- | Evaluate the REPL logic into a MonadException context.
evalRepl :: MonadException m             -- Terminal monad ( often IO ).
         => String                       -- ^ Banner
         -> Command (HaskelineT m)       -- ^ Command function
         -> Options (HaskelineT m)       -- ^ Options list and commands
         -> CompleterStyle m             -- ^ Tab completion function
         -> HaskelineT m a               -- ^ Initializer
         -> m ()
evalRepl banner cmd opts comp initz = runHaskelineT _readline (initz >> monad)
  where
    monad = replLoop banner cmd opts
    _readline = H.Settings
      { H.complete       = mkCompleter comp
      , H.historyFile    = Just ".history"
      , H.autoAddHistory = True
      }

-- | Evaluate the REPL logic with the settings record.
evalReplWith :: MonadException m => ReplSettings m -> m ()
evalReplWith settings = runHaskelineT _readline (tryAction monad)
  where
    monad = replLoop (_banner settings) (_cmd settings) (_opts settings)
    _readline = H.Settings
      { H.complete       = mkCompleter (_compstyle settings)
      , H.historyFile    = Just ".history"
      , H.autoAddHistory = True
      }

-------------------------------------------------------------------------------
-- Completions
-------------------------------------------------------------------------------

data CompleterStyle m
  = Word (WordCompleter m)       -- ^ Completion function takes single word.
  | Cursor (LineCompleter m)     -- ^ Completion function takes tuple of full line.
  | File                         -- ^ Completion function completes files in CWD.
  | Mixed (CompletionFunc m)     -- ^ Function manually manipulates readline result.

mkCompleter :: MonadIO m => CompleterStyle m -> CompletionFunc m
mkCompleter (Word f)   = completeWord (Just '\\') " \t()[]" f
mkCompleter (Cursor f) = completeWordWithPrev (Just '\\') " \t()[]" f
mkCompleter File       = completeFilename
mkCompleter (Mixed f)  = f

trimComplete :: String -> Completion -> Completion
trimComplete prefix (Completion a b c) = Completion (drop (length prefix) a) b c
