module Termonad.Term where

import Termonad.Prelude

import Control.Lens
import GI.Gdk
  ( EventKey
  )
import GI.Gio
  ( noCancellable
  )
import GI.GLib
  ( SpawnFlags(SpawnFlagsDefault)
  )
import GI.Gtk
  ( Application
  , ApplicationWindow(ApplicationWindow)
  , Box(Box)
  , CssProvider(CssProvider)
  , Dialog(Dialog)
  , Notebook(Notebook)
  , ScrolledWindow(ScrolledWindow)
  , pattern STYLE_PROVIDER_PRIORITY_APPLICATION
  , applicationNew
  , applicationSetAccelsForAction
  , builderNewFromString
  , builderSetApplication
  , containerAdd
  , noAdjustment
  , notebookAppendPage
  , notebookDetachTab
  , notebookSetCurrentPage
  , notebookSetTabLabelText
  , noWidget
  , onWidgetKeyPressEvent
  , scrolledWindowNew
  , setWidgetHasFocus
  , styleContextAddProviderForScreen
  , widgetShow
  )
import GI.Vte
  ( CursorBlinkMode(CursorBlinkModeOn)
  , PtyFlags(PtyFlagsDefault)
  , onTerminalChildExited
  , onTerminalWindowTitleChanged
  , terminalGetWindowTitle
  , terminalNew
  , terminalSetCursorBlinkMode
  , terminalSetFont
  , terminalSpawnSync
  )

import Termonad.FocusList
import Termonad.Types
import Termonad.Types (lensTMNotebookTabs)

import Text.Pretty.Simple

focusTerm :: Int -> TMState -> IO ()
focusTerm i mvarTMState = do
  putStrLn "In focusTerm, about to modify state..."
  modifyMVar_ mvarTMState $ focusTerm' i
  putStrLn "In focusTerm, finished modifying state."

focusTerm' :: Int -> TMState' -> IO TMState'
focusTerm' i oldTMState@TMState{tmStateNotebook} = do
  let tabs = tmNotebookTabs tmStateNotebook
      maybeNewTabs = updateFocusFL i tabs
  case maybeNewTabs of
    Nothing -> pure oldTMState
    Just (notebookTab, newTabs) -> do
      putStrLn "In focusTerm', about to set current page..."
      notebookSetCurrentPage (tmNotebook tmStateNotebook) (fromIntegral i)
      putStrLn "In focusTerm', finished setting current page."
      let term = notebookTab ^. lensTMNotebookTabTerm . lensTerm
      setWidgetHasFocus term True
      let newTMState =
            oldTMState & lensTMStateNotebook . lensTMNotebookTabs .~ newTabs
      pure newTMState

altNumSwitchTerm :: Int -> TMState -> IO ()
altNumSwitchTerm = focusTerm

termExitFocused :: TMState -> IO ()
termExitFocused mvarTMState =
  modifyMVar_ mvarTMState $ \tmState -> do
    let maybeTab =
          tmState ^. lensTMStateNotebook . lensTMNotebookTabs . to getFLFocusItem
    case maybeTab of
      Nothing -> trace "in termExitFocused, no tab" $ pure tmState
      Just tab -> trace ("in termExitFocused, found tab: " <> show tab) $ termExit' tab tmState

termExit :: TMNotebookTab -> TMState -> IO ()
termExit tab mvarTMState =
  modifyMVar_ mvarTMState $ termExit' tab

termExit' :: TMNotebookTab -> TMState' -> IO TMState'
termExit' tab tmState = do
  putStrLn "In termExit', tmState:"
  pPrint tmState
  let notebook = tmStateNotebook tmState
      note = tmNotebook notebook
      oldTabs = tmNotebookTabs notebook
      scrolledWin = tmNotebookTabTermContainer tab
  notebookDetachTab note scrolledWin
  let newTabs = deleteFL tab oldTabs
  let newTMState =
        set (lensTMStateNotebook . lensTMNotebookTabs) newTabs tmState
  putStrLn "In termExit', newTMState:"
  pPrint newTMState
  pure newTMState

termExitHandler :: TMNotebookTab -> TMState -> Int32 -> IO ()
termExitHandler tab mvarTMState _exitStatus = termExit tab mvarTMState

createScrolledWin :: IO ScrolledWindow
createScrolledWin = do
  scrolledWin <- scrolledWindowNew noAdjustment noAdjustment
  widgetShow scrolledWin
  pure scrolledWin

createTerm :: (TMState -> EventKey -> IO Bool) -> TMState -> IO TMTerm
createTerm handleKeyPress mvarTMState = do
  putStrLn "createTerm, started..."
  scrolledWin <- createScrolledWin
  TMState{tmStateFontDesc} <- readMVar mvarTMState
  vteTerm <- terminalNew
  terminalSetFont vteTerm (Just tmStateFontDesc)
  terminalSetCursorBlinkMode vteTerm CursorBlinkModeOn
  _termResVal <-
    terminalSpawnSync
      vteTerm
      [PtyFlagsDefault]
      Nothing
      ["/usr/bin/env", "bash"]
      Nothing
      ([SpawnFlagsDefault] :: [SpawnFlags])
      Nothing
      noCancellable
  widgetShow vteTerm
  tmTerm <- newTMTerm vteTerm
  let notebookTab = createTMNotebookTab scrolledWin tmTerm
  containerAdd scrolledWin vteTerm
  putStrLn "createTerm, created some stuff, about to go into mvar..."
  modifyMVar_ mvarTMState $ \tmState -> do
    putStrLn "createTerm, in mvar thing, started..."
    let notebook = tmStateNotebook tmState
        note = tmNotebook notebook
        tabs = tmNotebookTabs notebook
    putStrLn "createTerm, in mvar thing, about to notebookAppendPage..."
    pageIndex <- notebookAppendPage note scrolledWin noWidget
    putStrLn "createTerm, in mvar thing, about to notebookSetCurrentPage..."
    notebookSetCurrentPage note pageIndex
    let newTabs = appendSetFocusFL tabs notebookTab
    pure $
      tmState &
        lensTMStateNotebook . lensTMNotebookTabs .~ newTabs
  putStrLn "createTerm, after mvar thing..."
  void $ onTerminalWindowTitleChanged vteTerm $ do
    title <- terminalGetWindowTitle vteTerm
    TMState{tmStateNotebook} <- readMVar mvarTMState
    let notebook = tmNotebook tmStateNotebook
    notebookSetTabLabelText notebook scrolledWin title
  void $ onWidgetKeyPressEvent vteTerm $ handleKeyPress mvarTMState
  void $ onWidgetKeyPressEvent scrolledWin $ handleKeyPress mvarTMState
  void $ onTerminalChildExited vteTerm $
    termExitHandler notebookTab mvarTMState
  pure tmTerm
