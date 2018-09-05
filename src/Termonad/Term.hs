{-# LANGUAGE CPP #-}

module Termonad.Term where

import Termonad.Prelude

import Control.Lens ((^.), (&), (.~), set, to)
import Data.Colour.SRGB (Colour, RGB(RGB), toSRGB)
import GI.Gdk
  ( EventKey
  , RGBA
  , newZeroRGBA
  , setRGBABlue
  , setRGBAGreen
  , setRGBARed
  )
import GI.Gio
  ( noCancellable
  )
import GI.GLib
  ( SpawnFlags(SpawnFlagsDefault)
  )
import GI.Gtk
  ( Align(AlignFill)
  , Box
  , Button
  , IconSize(IconSizeMenu)
  , Label
  , Notebook
  , Orientation(OrientationHorizontal)
  , PolicyType(PolicyTypeAlways, PolicyTypeAutomatic, PolicyTypeNever)
  , ReliefStyle(ReliefStyleNone)
  , ResponseType(ResponseTypeNo, ResponseTypeYes)
  , ScrolledWindow
  , applicationGetActiveWindow
  , boxNew
  , buttonNewFromIconName
  , buttonSetRelief
  , containerAdd
  , dialogAddButton
  , dialogGetContentArea
  , dialogNew
  , dialogRun
  , labelNew
  , labelSetEllipsize
  , labelSetLabel
  , labelSetMaxWidthChars
  , noAdjustment
  , notebookAppendPage
  , notebookDetachTab
  , notebookPageNum
  , notebookSetCurrentPage
  , notebookSetTabReorderable
  , onButtonClicked
  , onWidgetKeyPressEvent
  , scrolledWindowNew
  , scrolledWindowSetPolicy
  , setWidgetMargin
  , widgetDestroy
  , widgetGrabFocus
  , widgetSetCanFocus
  , widgetSetHalign
  , widgetSetHexpand
  , widgetShow
  , windowSetTransientFor
  )
import GI.Pango (EllipsizeMode(EllipsizeModeMiddle))
import GI.Vte
  ( CursorBlinkMode(CursorBlinkModeOn)
  , PtyFlags(PtyFlagsDefault)
  , Terminal
  , onTerminalChildExited
  , onTerminalWindowTitleChanged
  , terminalGetWindowTitle
  , terminalNew
  , terminalSetCursorBlinkMode
  , terminalSetColors
  , terminalSetColorBackground
  , terminalSetColorForeground
  , terminalSetColorCursor
  , terminalSetFont
  , terminalSetScrollbackLines
  , terminalSpawnSync
  , terminalSetWordCharExceptions
  )
import System.FilePath ((</>))
import System.Directory (getSymbolicLinkTarget)

import Termonad.Config
  ( ShowScrollbar(..)
  , TMConfig(scrollbackLen, wordCharExceptions, colourConfig)
  , ColourConfig(..)
  , lensShowScrollbar
  , lensConfirmExit
  )
import Termonad.FocusList (appendFL, deleteFL, getFLFocusItem)
import Termonad.Types
  ( TMNotebookTab
  , TMState
  , TMState'(TMState, tmStateConfig, tmStateFontDesc, tmStateNotebook)
  , TMTerm
  , createTMNotebookTab
  , lensTerm
  , lensTMNotebookTabLabel
  , lensTMNotebookTabs
  , lensTMNotebookTabTerm
  , lensTMNotebookTabTermContainer
  , lensTMStateApp
  , lensTMStateConfig
  , lensTMStateNotebook
  , newTMTerm
  , pid
  , tmNotebook
  , tmNotebookTabs
  , tmNotebookTabTerm
  , tmNotebookTabTermContainer
  )

focusTerm :: Int -> TMState -> IO ()
focusTerm i mvarTMState = do
  note <- tmNotebook . tmStateNotebook <$> readMVar mvarTMState
  notebookSetCurrentPage note (fromIntegral i)

altNumSwitchTerm :: Int -> TMState -> IO ()
altNumSwitchTerm = focusTerm

termExitFocused :: TMState -> IO ()
termExitFocused mvarTMState = do
  tmState <- readMVar mvarTMState
  let maybeTab =
        tmState ^. lensTMStateNotebook . lensTMNotebookTabs . to getFLFocusItem
  case maybeTab of
    Nothing -> pure ()
    Just tab -> termClose tab mvarTMState

termClose :: TMNotebookTab -> TMState -> IO ()
termClose tab mvarTMState = do
  tmState <- readMVar mvarTMState
  let confirm = tmState ^. lensTMStateConfig ^. lensConfirmExit
      close = if confirm then termExitWithConfirmation else termExit
  close tab mvarTMState

termExitWithConfirmation :: TMNotebookTab -> TMState -> IO ()
termExitWithConfirmation tab mvarTMState = do
  tmState <- readMVar mvarTMState
  let app = tmState ^. lensTMStateApp
  win <- applicationGetActiveWindow app
  dialog <- dialogNew
  box <- dialogGetContentArea dialog
  label <- labelNew (Just "Close tab?")
  containerAdd box label
  widgetShow label
  setWidgetMargin label 10
  void $
    dialogAddButton
      dialog
      "No, do NOT close tab"
      (fromIntegral (fromEnum ResponseTypeNo))
  void $
    dialogAddButton
      dialog
      "Yes, close tab"
      (fromIntegral (fromEnum ResponseTypeYes))
  windowSetTransientFor dialog win
  res <- dialogRun dialog
  widgetDestroy dialog
  case toEnum (fromIntegral res) of
    ResponseTypeYes -> termExit tab mvarTMState
    _ -> pure ()

termExit :: TMNotebookTab -> TMState -> IO ()
termExit tab mvarTMState = do
  detachTabAction <-
    modifyMVar mvarTMState $ \tmState -> do
      let notebook = tmStateNotebook tmState
          detachTabAction =
            notebookDetachTab
              (tmNotebook notebook)
              (tmNotebookTabTermContainer tab)
      let newTabs = deleteFL tab (tmNotebookTabs notebook)
      let newTMState =
            set (lensTMStateNotebook . lensTMNotebookTabs) newTabs tmState
      pure (newTMState, detachTabAction)
  detachTabAction
  relabelTabs mvarTMState

relabelTabs :: TMState -> IO ()
relabelTabs mvarTMState = do
  TMState{tmStateNotebook} <- readMVar mvarTMState
  let notebook = tmNotebook tmStateNotebook
      tabFocusList = tmNotebookTabs tmStateNotebook
  foldMap (go notebook) tabFocusList
  where
    go :: Notebook -> TMNotebookTab -> IO ()
    go notebook tmNotebookTab = do
      let label = tmNotebookTab ^. lensTMNotebookTabLabel
          scrolledWin = tmNotebookTab ^. lensTMNotebookTabTermContainer
          term' = tmNotebookTab ^. lensTMNotebookTabTerm . lensTerm
      relabelTab notebook label scrolledWin term'

relabelTab :: Notebook -> Label -> ScrolledWindow -> Terminal -> IO ()
relabelTab notebook label scrolledWin term' = do
  pageNum <- notebookPageNum notebook scrolledWin
  maybeTitle <- terminalGetWindowTitle term'
  let title = fromMaybe "bash" maybeTitle
  labelSetLabel label $ tshow (pageNum + 1) <> ". " <> title

showScrollbarToPolicy :: ShowScrollbar -> PolicyType
showScrollbarToPolicy ShowScrollbarNever = PolicyTypeNever
showScrollbarToPolicy ShowScrollbarIfNeeded = PolicyTypeAutomatic
showScrollbarToPolicy ShowScrollbarAlways = PolicyTypeAlways

createScrolledWin :: TMState -> IO ScrolledWindow
createScrolledWin mvarTMState = do
  tmState <- readMVar mvarTMState
  let showScrollbarVal = tmState ^. lensTMStateConfig . lensShowScrollbar
      vScrollbarPolicy = showScrollbarToPolicy showScrollbarVal
  scrolledWin <- scrolledWindowNew noAdjustment noAdjustment
  widgetShow scrolledWin
  scrolledWindowSetPolicy scrolledWin PolicyTypeAutomatic vScrollbarPolicy
  pure scrolledWin

createNotebookTabLabel :: IO (Box, Label, Button)
createNotebookTabLabel = do
  box <- boxNew OrientationHorizontal 5
  label <- labelNew (Just "")
  labelSetEllipsize label EllipsizeModeMiddle
  labelSetMaxWidthChars label 10
  widgetSetHexpand label True
  widgetSetHalign label AlignFill
  button <-
    buttonNewFromIconName
      (Just "window-close")
      (fromIntegral (fromEnum IconSizeMenu))
  buttonSetRelief button ReliefStyleNone
  containerAdd box label
  containerAdd box button
  widgetSetCanFocus button False
  widgetSetCanFocus label False
  widgetSetCanFocus box False
  widgetShow box
  widgetShow label
  widgetShow button
  pure (box, label, button)

toRGBA :: Colour Double -> IO RGBA
toRGBA colour = do
  let RGB red green blue = toSRGB colour
  rgba <- newZeroRGBA
  setRGBARed rgba red
  setRGBAGreen rgba green
  setRGBABlue rgba blue
  pure rgba

-- | TODO: This should probably be implemented in an external package,
-- since it is a generally useful utility.
--
-- It should also be implemented for windows and osx.
cwdOfPid :: Int -> IO (Maybe Text)
cwdOfPid pd = do
#ifdef mingw32_HOST_OS
  pure Nothing
#else
#ifdef darwin_HOST_OS
  pure Nothing
#else
  let pidPath = "/proc" </> show pd </> "cwd"
  eitherLinkTarget <- try $ getSymbolicLinkTarget pidPath
  case eitherLinkTarget of
    Left (_ :: IOException) -> pure Nothing
    Right linkTarget -> pure $ Just $ pack linkTarget
#endif
#endif


createTerm :: (TMState -> EventKey -> IO Bool) -> TMState -> IO TMTerm
createTerm handleKeyPress mvarTMState = do
  scrolledWin <- createScrolledWin mvarTMState
  TMState{tmStateFontDesc, tmStateConfig, tmStateNotebook=currNote} <- readMVar mvarTMState
  let maybeCurrFocusedTabPid = pid . tmNotebookTabTerm <$> getFLFocusItem (tmNotebookTabs currNote)
  maybeCurrDir <- maybe (pure Nothing) cwdOfPid maybeCurrFocusedTabPid
  vteTerm <- terminalNew
  terminalSetFont vteTerm (Just tmStateFontDesc)
  terminalSetWordCharExceptions vteTerm $ wordCharExceptions tmStateConfig
  terminalSetScrollbackLines vteTerm (fromIntegral (scrollbackLen tmStateConfig))
  let colourConf = colourConfig tmStateConfig
      mGetRGBA accessor = Just <$> toRGBA (accessor colourConf)
  terminalSetColorCursor vteTerm =<< mGetRGBA cursorColour
  terminalSetColors vteTerm Nothing Nothing . Just =<< traverse toRGBA (palette colourConf)
  terminalSetCursorBlinkMode vteTerm CursorBlinkModeOn
  widgetShow vteTerm
  widgetGrabFocus $ vteTerm
  terminalProcPid <-
    terminalSpawnSync
      vteTerm
      [PtyFlagsDefault]
      maybeCurrDir
      ["/usr/bin/env", "bash"]
      Nothing
      ([SpawnFlagsDefault] :: [SpawnFlags])
      Nothing
      noCancellable
  tmTerm <- newTMTerm vteTerm (fromIntegral terminalProcPid)
  containerAdd scrolledWin vteTerm
  (tabLabelBox, tabLabel, tabCloseButton) <- createNotebookTabLabel
  let notebookTab = createTMNotebookTab tabLabel scrolledWin tmTerm
  void $
    onButtonClicked tabCloseButton $
      termClose notebookTab mvarTMState
  setCurrPageAction <-
    modifyMVar mvarTMState $ \tmState -> do
      let notebook = tmStateNotebook tmState
          note = tmNotebook notebook
          tabs = tmNotebookTabs notebook
      pageIndex <- notebookAppendPage note scrolledWin (Just tabLabelBox)
      notebookSetTabReorderable note scrolledWin True
      let newTabs = appendFL tabs notebookTab
          newTMState =
            tmState & lensTMStateNotebook . lensTMNotebookTabs .~ newTabs
          setCurrPageAction = do
            notebookSetCurrentPage note pageIndex
      pure (newTMState, setCurrPageAction)
  setCurrPageAction
  relabelTab (tmNotebook currNote) tabLabel scrolledWin vteTerm
  void $ onTerminalWindowTitleChanged vteTerm $ do
    TMState{tmStateNotebook} <- readMVar mvarTMState
    let notebook = tmNotebook tmStateNotebook
    relabelTab notebook tabLabel scrolledWin vteTerm
  void $ onWidgetKeyPressEvent vteTerm $ handleKeyPress mvarTMState
  void $ onWidgetKeyPressEvent scrolledWin $ handleKeyPress mvarTMState
  void $ onTerminalChildExited vteTerm $ \_ -> termExit notebookTab mvarTMState
  pure tmTerm
