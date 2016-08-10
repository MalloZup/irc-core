{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
module Main where

import Control.Applicative hiding ((<|>))
import Control.Concurrent (killThread, forkIO)
import Control.Concurrent.STM
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.Trans.State
import Control.Monad.IO.Class
import Data.ByteString (ByteString)
import Data.Char
import Data.Fixed (Centi, Pico, showFixed)
import Data.Foldable (for_, traverse_)
import Data.List (elemIndex)
import Data.List.Split (chunksOf)
import Data.IORef
import Data.Maybe (fromMaybe, fromJust)
import Data.Monoid
import Data.Set (Set)
import Data.Text (Text)
import Data.Time
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Traversable (for)
import Graphics.Vty
import Network.Connection
import System.IO
import System.IO.Error (isEOFError)
import qualified Config.Lens as C
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Lens as Text
import qualified Data.Text.Encoding as Text

import Irc.Core
import Irc.Cmd
import Irc.Format
import Irc.Message
import Irc.Model
import Irc.RateLimit

import ConnectCmds (connectCmds)
import ClientState
import Connection (connect, getRawIrcLine)
import CommandArgs
import CommandParser
import CtcpHandler
import ImageUtils
import Moderation
import ServerSettings
import Views.BanList
import Views.Channel
import Views.ChannelInfo
import Views.DCC
import qualified EditBox as Edit

data SendType = SendCtcp String | SendPriv | SendNotice | SendAction
makePrisms ''SendType

main :: IO ()
main = do
  args <- getCommandArgs

  let debugFile = view cmdArgDebug args
                `mplus`
                  preview ( cmdArgConfigValue
                          . C.key "debug-file"
                          . C.text . Text.unpacked) args

      outDir = fromJust (preview ( cmdArgConfigValue . C.key "download-dir"
                                 . C.text . Text.unpacked ) args
                         `mplus` (Just "~"))

  hErr <- for debugFile $ \fn ->
            do hErr <- openFile fn WriteMode
               hSetBuffering hErr NoBuffering
               return hErr

  vtyEventChan <- atomically newTChan
  recvChan     <- atomically newTChan

  withVty $ \vty ->
    do _ <- forkIO (vtyEventLoop vtyEventChan vty)
       settings <- initialServerSettings args
       server0  <- startIrcConnection recvChan settings hErr
       (width,height) <- displayBounds (outputIface vty)
       zone <- getCurrentTimeZone

       let st0 = ClientState
               { _clientServer0         = server0
               , _clientRecvChan        = recvChan
               , _clientErrors          = hErr
               , _clientFocus           = ChannelFocus ""
               , _clientDetailView      = False
               , _clientTimeView        = True
               , _clientMetaView        = True
               , _clientFullView        = False
               , _clientEditBox         = Edit.empty
               , _clientTabPattern      = Nothing
               , _clientScrollPos       = 0
               , _clientHeight          = height
               , _clientWidth           = width
               , _clientIgnores         = mempty
               , _clientHighlights      = mempty
               , _clientMessages        = mempty
               , _clientNickColors      = defaultNickColors
               , _clientAutomation      = [dccHandler outDir, ctcpHandler
                                          ,cancelDeopTimerOnDeop, connectCmds]
               , _clientTimers          = mempty
               , _clientTimeZone        = zone
               }
       st1 <- schedulePing st0

       driver vty vtyEventChan recvChan st1

withVty :: (Vty -> IO a) -> IO a
withVty k =
  do cfg <- standardIOConfig
     bracket (mkVty cfg) shutdown k

startIrcConnection ::
  TChan (UTCTime, MsgFromServer) {- ^ incoming client events -} ->
  ServerSettings                 {- ^ network parameters     -} ->
  Maybe Handle                   {- ^ error log              -} ->
  IO ClientConnection
startIrcConnection recvChan settings hErr =
  do connectRes <- try (connect settings)
     case connectRes of
       Left e -> connectionFailed e
       Right h -> connectionSuceeded h

  where
  utf8Bytes = Text.encodeUtf8 . Text.pack
  nick = mkId (utf8Bytes (view ssNick settings))
  user = utf8Bytes (view ssUser settings)
  real = utf8Bytes (view ssReal settings)
  sasl = over (mapped.both) utf8Bytes (view ssSaslCredential settings)
  pass = over mapped        utf8Bytes (view ssPassword settings)

  connectionSuceeded h =
    do sendChan     <- atomically newTChan
       connectedRef <- newIORef True
       sendThreadId <- forkIO (sendLoop connectedRef sendChan h)
       recvThreadId <- forkIO (socketLoop recvChan h hErr)
       initializeConnection pass nick user real h
       return ClientConnection
         { _ccServerSettings = settings
         , _ccConnection     = defaultIrcConnection
                                 { _connNick = nick
                                 , _connSasl = sasl
                                 }
         , _ccSendChan       = Just (connectedRef, sendChan)
         , _ccRecvThread     = Just recvThreadId
         , _ccSendThread     = Just sendThreadId
         , _ccHoldDccTrans   = (Map.empty, Map.empty)
         }

  connectionFailed (SomeException e) =
    do let eUtf8 = utf8Bytes (show e)
       now <- getCurrentTime
       atomically (writeTChan recvChan (now, Error eUtf8))
       return ClientConnection
         { _ccServerSettings = settings
         , _ccConnection     = defaultIrcConnection
                                 { _connNick = nick
                                 , _connSasl = sasl
                                 }
         , _ccSendChan       = Nothing
         , _ccRecvThread     = Nothing
         , _ccSendThread     = Nothing
         , _ccHoldDccTrans   = (Map.empty, Map.empty)
         }

initializeConnection ::
  Maybe ByteString {- ^ server password -} ->
  Identifier {- ^ nickname        -} ->
  ByteString {- ^ username        -} ->
  ByteString {- ^ realname        -} ->
  Connection -> IO ()
initializeConnection pass nick user real h =
  do connectionPut h capLsCmd
     traverse_ (connectionPut h . passCmd) pass
     connectionPut h (nickCmd nick)
     connectionPut h (userCmd user real)

driver :: Vty -> TChan Event -> TChan (UTCTime, MsgFromServer) -> ClientState -> IO ()
driver vty vtyEventChan ircMsgChan st0 =
  do now <- getCurrentTime
     let (scroll', pic) = picForState now st0
         st1 = set clientScrollPos scroll' st0
     update vty pic
     e <- readEitherTChan vtyEventChan ircMsgChan
     case e of
       Left vtyEvent -> processVtyEvent st1 vtyEvent
       Right (time,msg) -> processIrcMsg st1 time msg

  where
  -- processVtyEvent and processIrcMsg jump here
  continue = considerTimers
           . resetCurrentChannelMessages
           <=< pruneStaleOffers
           <=< updateTransfers

  considerTimers st =
    do now <- getCurrentTime
       case nextTimerEvent now st of
         Nothing -> driver vty vtyEventChan ircMsgChan st
         Just (e,st') -> processTimerEvent e st'

  processTimerEvent e st =
    case e of
      TransmitPing ->
        do let server = view (clientServer0 . ccServerSettings . ssHostName) st
           st1 <- doPingCmd  server st
           st2 <- schedulePing st1
           considerTimers st2

      DropOperator chan ->
        do clientSend (modeCmd chan ["-o",views connNick idBytes conn]) st
           considerTimers st
    where
    conn = view (clientServer0 . ccConnection) st

  processVtyEvent st event =
    case event of
      EvResize width height -> continue
                             $ set clientWidth  width
                             $ set clientHeight height st

      EvKey (KChar 'l') [MCtrl] ->
        do refresh vty
           (width,height) <- displayBounds (outputIface vty)
           continue $ set clientHeight height
                    $ set clientWidth  width st

      EvKey key mods -> do r <- keyEvent key mods st
                           case r of
                             KeepGoing st' -> continue st'
                             Exit -> return ()

      _ -> continue st

  processIrcMsg st time msg =
    do let m :: IO (Either String IrcConnection, ClientState)
           m = flip runStateT st
             $ runLogic time
                  (interpretLogicOp ircMsgChan)
                  (advanceModel msg
                     (view (clientServer0 . ccConnection) st))

       res <- m
       case res of
         (Left e,st') ->
           do for_ (view clientErrors st) $ \h -> hPutStrLn h ("!!! " ++ e)
              continue st'
         (Right conn',st') ->
           do continue (set (clientServer0 . ccConnection) conn' st')

interpretLogicOp :: TChan (UTCTime, MsgFromServer) -> LogicOp a -> StateT ClientState IO a

interpretLogicOp ircMsgChan (Expect k) =
  do fmap (k.snd) (liftIO (atomically (readTChan ircMsgChan)))

interpretLogicOp _ (Emit bytes r) =
  do st <- get
     liftIO (clientSend bytes st)
     return r

interpretLogicOp _ (Record target message r) =
  do put =<< liftIO . runEventHandlers target message
                    . addMessage target message
         =<< get
     return r

------------------------------------------------------------------------
-- Key Event Handlers!
------------------------------------------------------------------------

data KeyEventResult
  = KeepGoing ClientState
  | Exit

changeInput :: (Edit.EditBox -> Edit.EditBox) -> ClientState -> ClientState
changeInput f st = clearTabPattern (over clientEditBox f st)

inputLogic :: ClientState -> (Image, IO KeyEventResult)
inputLogic st =
  case clientInput st of
    '/':_ -> case commandEvent st of
               (img, Nothing) -> (img, return (KeepGoing st))
               (img, Just m ) -> (img, m)
    txt -> ( ircFormattedText' explicitFormatting (Text.pack txt)
           , fmap KeepGoing (doSendMessageCurrent SendPriv st)
           )

keyEvent :: Key -> [Modifier] -> ClientState -> IO KeyEventResult
keyEvent k ms st =
  let more = return . KeepGoing in
  case (k,ms) of
    (KFun 2   , []     ) -> more $ over clientDetailView not st
    (KFun 3   , []     ) -> more $ over clientTimeView   not st
    (KFun 4   , []     ) -> more $ over clientMetaView   not st
    (KFun 5   , []     ) -> more $ over clientFullView   not st
    (KPageUp  , _      ) -> more $ scrollUp st
    (KPageDown, _      ) -> more $ scrollDown st
    (KChar 'n', [MCtrl]) -> more $ nextFocus st
    (KChar 'p', [MCtrl]) -> more $ prevFocus st
    (KChar c  , [MMeta]) | Just i <- jumpNumber c -> more $ jumpFocus i st
    (KChar 'a', [MMeta]) -> more $ jumpActivity st
    (KBS      , _      ) -> more $ changeInput Edit.backspace st
    (KChar 'd', [MCtrl]) -> more $ changeInput Edit.delete st
    (KDel     , _      ) -> more $ changeInput Edit.delete st
    (KUp      , _      ) -> more $ maybe st clearTabPattern $ clientEditBox Edit.earlier st
    (KDown    , _      ) -> more $ maybe st clearTabPattern $ clientEditBox Edit.later st
    (KLeft    , _      ) -> more $ changeInput Edit.left st
    (KRight   , _      ) -> more $ changeInput Edit.right st
    (KHome    , _      ) -> more $ changeInput Edit.home st
    (KEnd     , _      ) -> more $ changeInput Edit.end st
    (KChar 'a', [MCtrl]) -> more $ changeInput Edit.home st
    (KChar 'e', [MCtrl]) -> more $ changeInput Edit.end st
    (KChar 'u', [MCtrl]) -> more $ changeInput Edit.killHome st
    (KChar 'k', [MCtrl]) -> more $ changeInput Edit.killEnd st
    (KChar 'y', [MCtrl]) -> more $ changeInput Edit.paste st
    (KChar 'w', [MCtrl]) -> more $ changeInput (Edit.killWord True) st
    (KChar 'b', [MMeta]) -> more $ changeInput Edit.leftWord st
    (KChar 'f', [MMeta]) -> more $ changeInput Edit.rightWord st
    (KChar '\t', []    ) -> more $ tabComplete st
    (KChar 'b', [MCtrl]) -> more $ changeInput (Edit.insert '\^B') st
    (KChar 'c', [MCtrl]) -> more $ changeInput (Edit.insert '\^C') st
    (KChar ']', [MCtrl]) -> more $ changeInput (Edit.insert '\^]') st
    (KChar '_', [MCtrl]) -> more $ changeInput (Edit.insert '\^_') st
    (KChar 'o', [MCtrl]) -> more $ changeInput (Edit.insert '\^O') st
    (KChar 'v', [MCtrl]) -> more $ changeInput (Edit.insert '\^V') st
    (KChar c  , []     ) -> more $ changeInput (Edit.insert c) st
    (KEnter   , []     ) -> snd (inputLogic st)
    _                    -> more st

-- | Map keyboard numbers 1-9,0 to the numbers 0-9
jumpNumber :: Char -> Maybe Int
jumpNumber c = elemIndex c jumps
  where
  jumps = "1234567890qwertyuiop"


-- TODO: Don't scroll off the end of the channel

scrollOffset :: ClientState -> Int
scrollOffset st = max 1 (view clientHeight st - 4)

scrollUp :: ClientState -> ClientState
scrollUp st = over clientScrollPos (+ scrollOffset st) st

scrollDown :: ClientState -> ClientState
scrollDown st = over clientScrollPos (\x -> max 0 (x - scrollOffset st)) st

doSendMessageCurrent :: SendType -> ClientState -> IO ClientState
doSendMessageCurrent sendType st =
  case view clientFocus st of
    ChannelFocus c
      | not (null (dropWhile isSpace (clientInput st))) ->
      doSendMessage sendType c (Text.pack (clientInput st)) st
    _ -> return st

-- Pessimistic maximum length computation for the message part for
-- privmsg and notice. Note that the need for the limit is because
-- the server will limit the length of the message sent out to each
-- client, not just the length of the messages it will recieve.
computeMaxMessageLength :: Identifier -> String -> Identifier -> Int
computeMaxMessageLength nick user target
  = 512
  - 63 -- max hostname
  - length (":~!@ PRIVMSG :\r\n"::String)
  - B8.length (idBytes nick)
  - length user
  - B8.length (idBytes target)

doSendMessage :: SendType -> Identifier -> Text -> ClientState -> IO ClientState

doSendMessage sendType _ message st
  | Text.null message && hasn't _SendCtcp sendType = return st

doSendMessage sendType target message st =
  do let bs = case sendType of
                SendPriv -> map (privMsgCmd target . Text.encodeUtf8) messages
                                -- long actions aren't split up
                SendAction -> [privMsgCmd target ("\SOHACTION " <>
                                                 Text.encodeUtf8 message <> "\SOH")]
                SendNotice -> map (noticeCmd target . Text.encodeUtf8) messages
                SendCtcp cmd -> [ctcpRequestCmd target
                                 (Text.encodeUtf8 (Text.pack (map toUpper cmd)))
                                 (Text.encodeUtf8 message)]
     mapM_ (`clientSend` st) bs
     now <- getCurrentTime
     let myModes = view (connChannels . ix target' . chanUsers . ix myNick) conn
     return (addMessage target' (fakeMsg now myModes) (clearInput st))

  where
  myNick = view connNick conn

  maxMessageLength =
    computeMaxMessageLength myNick (view (ccServerSettings.ssUser) ircconn) target
  messages = Text.chunksOf maxMessageLength message

  ircconn = view clientServer0 st
  conn = view ccConnection ircconn

  (statusmsg, target') = splitStatusMsg target conn

  fakeMsg now modes = IrcMessage
    { _mesgSender = who
    , _mesgStatus = statusmsg
    , _mesgType = case sendType of
                    SendPriv   -> PrivMsgType   message
                    SendNotice -> NoticeMsgType message
                    SendAction -> ActionMsgType message
                    SendCtcp cmd -> CtcpReqMsgType
                                        (Text.encodeUtf8 (Text.pack cmd))
                                        (Text.encodeUtf8 message)
    , _mesgStamp = now
    , _mesgModes = modes
    , _mesgMe = True
    }

  who = UserInfo (view connNick conn) Nothing Nothing

commandEvent :: ClientState -> (Image, Maybe (IO KeyEventResult))
commandEvent st = commandsParser (clientInput st)
                        (exitCommand : dccCommand : normalCommands)
 where
 st' = clearInput st
 toB = Text.encodeUtf8 . Text.pack
 conn = view (clientServer0 . ccConnection) st

 exitCommand =
  ("exit", [], pure (return Exit))

 dccCommand :: (String, [String], Parser (IO KeyEventResult))
 dccCommand =
   let popAndLaunch = fmap (fmap KeepGoing) $ startOffer st'
       popOrKill    = fmap (fmap KeepGoing) $ cancelOffer st'
       cmdBranch a = case a of
                       "accept" -> popAndLaunch
                       "cancel" -> popOrKill
                       _        -> Nothing

    in ("dcc", [], pValidToken "(accept|cancel)" cmdBranch )

 normalCommands = over (mapped . _3 . mapped . mapped) KeepGoing $
    -- focus setting
  [ ("server", [],
    pure (return (set clientFocus (ChannelFocus "") st')))

  , ("channel", [],
    (\chan -> return (set clientFocus (ChannelFocus chan) st'))
    <$> pChannel st)

  , ("query", [],
    (\user -> return (set clientFocus (ChannelFocus user) st'))
    <$> pNick st)

  , ("window", [],
    (\n -> return (jumpFocus n st'))
    <$> pNumber)

  , ("channelinfo", [], pure (doChannelInfoCmd st))

  , ("transfers", [], pure (doDccTransfers st))

  , ("bans", [], pure (doMasksCmd 'b' st))

  , ("masks", [],
    (\mode -> doMasksCmd mode st)
    <$> pValidToken "mode" (\m ->
            case m of
              [x] | x `elem` view (connChanModeTypes . modesLists) conn ->
                   Just x
              _ -> Nothing))

    -- chat
  , ("me", [],
    (\msg -> doAction msg st)
    <$> pRemainingNoSp)

  , ("notice", [],
    (\target msg -> doSendMessage SendNotice target (Text.pack msg) st)
    <$> pTarget <*> pRemainingNoSp)

  , ("msg", [],
    (\target msg -> doSendMessage SendPriv target (Text.pack msg) st)
    <$> pTarget <*> pRemainingNoSp)

  , ("ctcp", [],
    (\command params -> doSendMessage (SendCtcp command) (focusedName st) (Text.pack params) st)
    <$> pToken "command" <*> pRemainingNoSp)

    -- carefully preserve whitespace after the command
  , ("hs", [],
    (\src ->
      let msg = Text.pack src in
      case view clientFocus st of
        ChannelFocus c -> doSendMessage SendPriv c msg st
        _ -> return st)
    <$> pHaskell)

    -- raw
  , ("quote", [],
    (\rest -> doQuote rest st')
    <$> pRemainingNoSp)

  , ("help", [],
    (\mbTopic -> st' <$ clientSend (helpCmd (maybe "" toB mbTopic)) st')
    <$> optional (pToken "topic"))

    -- channel commands
  , ("join", ["j"],
    (\c key -> doJoinCmd c (fmap toB key) st')
    <$> pChannel st <*> optional (pToken "key"))

  , ("umode", [],
    (\args ->
         st' <$ clientSend (modeCmd (view connNick conn)
                                    (map toB (words args))) st')
    <$> pRemainingNoSp)

  , ("mode", [],
    (\args -> doMode (Text.encodeUtf8 (Text.pack args)) st)
    <$> pRemainingNoSp)

  , ("kick", [], doKick st <$> pNick st <*> (Text.pack <$> pRemainingNoSp))

  , ("remove", [], doRemove st <$> pNick st <*> (Text.pack <$> pRemainingNoSp))

  , ("invite", [], doInvite st <$> pNick st)

  , ("knock", [],
    (\chan -> doKnock chan st)
    <$> pChannel st)

  , ("part", [],
    (\msg -> case focusedChan st of
               Nothing -> return st
               Just chan -> st' <$ clientSend (partCmd chan (toB msg)) st')
    <$> pRemainingNoSp)

  , ("whois", ["wi"],
    (\u -> st' <$ clientSend (whoisCmd u) st')
    <$> pNick st)

  , ("whowas", [],
    (\u -> st' <$ clientSend (whowasCmd u) st')
    <$> pNick st)

  , ("topic", ["t"],
    (\rest -> doTopicCmd (toB rest) st) -- TODO: the limit should check bytes not chars
    <$> pRemainingNoSpLimit (view connTopicLen conn))

  , ("ignore", [],
    (\u -> return (over (clientIgnores . contains u) not st'))
    <$> pNick st)

  , ("highlight", [],
    (\w ->
       return (over (clientHighlights . contains (ircFoldCase (Text.encodeUtf8 (Text.pack w)))) not st'))
    <$> pRemainingNoSp)

  , ("clear", [],
    (\chan -> return (set (clientMessages . at (fromMaybe (focusedName st) chan)) Nothing st'))
    <$> optional pTarget)

  , ("accept", [],
    (\mbNick -> doAccept True mbNick st)
    <$> optional (pNick st))

  , ("unaccept", [],
    (\mbNick -> doAccept False mbNick st)
    <$> optional (pNick st))

  , ("acceptlist", [], pure (doAccept True (Just "*") st))

  , ("nick", [], doNick st
    <$> pNick st)

  , ("away", [],
    (\rest -> st' <$ clientSend (awayCmd (toB rest)) st')
    <$> pRemainingNoSp)

  , ("quit", [],
    (\rest -> st' <$ clientSend (quitCmd (toB rest)) st')
    <$> pRemainingNoSp)

  , ("who", [],
    (\whomask -> st' <$ clientSend (whoCmd (toB whomask)) st')
    <$> pToken "mask")

  , ("op"     , [], doOp st      <$> many' (pNick st))
  , ("deop"   , [], doDeop st    <$> many' (pNick st))
  , ("voice"  , [], doVoice st   <$> many' (pNick st))
  , ("devoice", [], doDevoice st <$> many' (pNick st))

  , ("akb", [],
    (\nick reason ->
       case focusedChan st of
         Nothing -> return st
         Just chan -> doWithOps chan (doAutoKickBan chan nick (Text.pack reason)) st')
    <$> pNick st <*> pRemainingNoSp)

  , ("time", [],
    (\mbServer -> st' <$ clientSend (timeCmd (fmap (Text.encodeUtf8 . Text.pack) mbServer)) st')
    <$> optional (pToken "server"))

  , ("admin", [],
    (\mbServer -> st' <$ clientSend (adminCmd (fmap (Text.encodeUtf8 . Text.pack) mbServer)) st')
    <$> optional (pToken "server"))

  , ("stats", [],
    (\letter mbTarget ->
        st' <$ clientSend (statsCmd letter (fmap (Text.encodeUtf8 . Text.pack) mbTarget)) st')
    <$> pAnyChar <*> optional (pToken "target"))

  , ("oper", [],
    (\user pass -> st' <$ clientSend (operCmd (Text.encodeUtf8 (Text.pack user))
                                              (Text.encodeUtf8 (Text.pack pass))) st')
    <$> pToken "username" <*> pToken "password")

  , ("reconnect", [], pure (doReconnect st'))

  , ("ping", [],
    (\msg -> doPingCmd msg st')
    <$> pToken "server")

  ]

doPingCmd :: String -> ClientState -> IO ClientState
doPingCmd msg st =
  do clientSend (pingCmd (Text.encodeUtf8 (Text.pack msg))) st
     updatePingTime st

doReconnect :: ClientState -> IO ClientState
doReconnect st =
  do let server0 = view clientServer0 st
     traverse_ killThread (view ccRecvThread server0)
     traverse_ killThread (view ccSendThread server0)

     let settings = view ccServerSettings server0
         recvChan = view clientRecvChan st
         hErr     = view clientErrors st
     server0' <- startIrcConnection recvChan settings hErr
     return (set clientServer0 server0' st)

doNick ::
  ClientState ->
  Identifier {- ^ new nickname -} ->
  IO ClientState
doNick st nick
  | B8.length (idBytes nick) > view connNickLen conn
  = return st

  | view connPhase conn /= ActivePhase =
      let st' = clearInput
              $ set (clientServer0 . ccConnection . connNick) nick st in
      st' <$ clientSend (nickCmd nick) st'

  | otherwise =
      clearInput st <$ clientSend (nickCmd nick) st

  where
  conn = view (clientServer0 . ccConnection) st

doMode ::
  ByteString {- mode change -} ->
  ClientState -> IO ClientState
doMode args st = fromMaybe (return st) $
  do chan         <- focusedChan st
     modes:params <- Just (B8.words args)
     parsedModes  <- splitModes (view connChanModeTypes conn)
                        modes params
     let modeChunks = chunksOf (view connModes conn) parsedModes
     return $
       doWithOps chan (\evSt ->
         do for_ modeChunks $ \modeChunk ->
              clientSend (modeCmd chan (unsplitModes modeChunk)) evSt
            return evSt)
         (clearInput st)

  where
  conn = view (clientServer0 . ccConnection) st

doAccept ::
  Bool {- ^ add to list -} ->
  Maybe Identifier {- ^ optional nick -} ->
  ClientState -> IO ClientState
doAccept add mbNick st =
  case mbNick of
    Just n -> go n
    Nothing
      | isNickName (focusedName st) conn -> go (focusedName st)
      | otherwise -> return st

  where
  conn = view (clientServer0 . ccConnection) st
  go nick =
    do let nickBytes
             | add = idBytes nick
             | otherwise = "-" <> idBytes nick
       clientSend (acceptCmd nickBytes) st
       return (clearInput st)

doAction ::
  String {- ^ action text -} ->
  ClientState -> IO ClientState
doAction msg st =
  case view clientFocus st of
    ChannelFocus c -> doSendMessage SendAction c (Text.pack msg) (clearInput st)
    _ -> return st

doKnock ::
  Identifier {- ^ channel  -} ->
  ClientState -> IO ClientState
doKnock chan st
  | not available || not isChannel || inChannel = return st
  | otherwise = do clientSend (knockCmd chan) st
                   return (clearInput st)
  where
  conn = view (clientServer0 . ccConnection) st
  available = view connKnock conn
  inChannel = has (connChannels . ix chan) conn
  isChannel = isChannelName chan conn

doChannelInfoCmd ::
  ClientState -> IO ClientState
doChannelInfoCmd st

  | Just chan <- focusedChan st =

  do let modesKnown
           = has ( connChannels . ix chan . chanModes . folded) conn

     unless modesKnown $
       clientSend (modeCmd chan []) st
     return (clearInput (set clientFocus (ChannelInfoFocus chan) st))

  | otherwise = return st

  where
  conn = view (clientServer0 . ccConnection) st

doDccTransfers :: ClientState -> IO ClientState
doDccTransfers st =
  return . clearInput $
    case view clientFocus st of
      DCCFocus _ -> st   -- No recursive DCCFocus
      oldFocus   -> set clientFocus (DCCFocus oldFocus) st

doMasksCmd ::
  Char       {- ^ mode    -} ->
  ClientState -> IO ClientState
doMasksCmd mode st
  | Just chan <- focusedChan st =
  do let masksKnown =
           has ( connChannels . ix chan . chanMaskLists . ix mode) conn

     unless masksKnown $
       clientSend (modeCmd chan [B8.pack ['+',mode]]) st
     return (set clientFocus (MaskListFocus mode chan) (clearInput st))

  | otherwise = return st

  where
  conn = view (clientServer0 . ccConnection) st

doJoinCmd :: Identifier -> Maybe ByteString -> ClientState -> IO ClientState
doJoinCmd c mbKey st =
  do clientSend (joinCmd c mbKey) st
     -- When joining you can specify more than one channel split on commas
     let c' = mkId (B8.takeWhile (/=',') (idBytes c))
     return (set clientFocus (ChannelFocus c') st)

doQuote :: String -> ClientState -> IO ClientState
doQuote cmd st = st <$ clientSend (Text.encodeUtf8 (Text.pack (cmd ++ "\r\n"))) st


------------------------------------------------------------------------
-- Primary UI rendering
------------------------------------------------------------------------

picForState :: UTCTime -> ClientState -> (Int,Picture)
picForState now st = (scroll', pic)
  where
  conn = view (clientServer0 . ccConnection) st

  pic = Picture
    { picCursor = Cursor (min (view clientWidth st - 1)
                              (view (clientEditBox. Edit.pos) st+1))
                         (view clientHeight st - 1)
    , picLayers =
        [ translateY (view clientHeight st - 2)
             (divider <-> textbox st)
        , everythingBeforeInput
        ]
    , picBackground = ClearBackground
    }

  everythingBeforeInput = vertCat
    [ titlebar
    , string defAttr (replicate (view clientWidth st) '─')
    , mainFocusImage
    ]

  divider = dividerImage now st

  -- Pad the main image when it doesn't fill the screen
  -- so that it starts at the bottom of the frame
  startFromBottom :: Image -> Image
  startFromBottom img = pad 0 top 0 0 img
    where
    top = max 0 (view clientHeight st - 4 - imageHeight img)

  mainFocusImage
    = startFromBottom
    . vertCat
    . reverse
    $ scrolledLines

  (scroll', scrolledLines) = scrollList (view clientHeight st - 4)
                                        (view clientScrollPos st)
                                        wrappedLines

  wrappedLines = reverse . lineWrap (view clientWidth st) =<< mainFocusLines

  mainFocusLines =
    case view clientFocus st of
      MaskListFocus mode chan -> banListImage mode chan st
      ChannelInfoFocus chan -> channelInfoImage chan st
      DCCFocus _ -> dccImage st
      _ -> channelImage st

  titlebar =
    case view clientFocus st of
      ChannelFocus "" -> string defAttr "Server"
      ChannelFocus c -> topicbar c
      ChannelInfoFocus c -> string defAttr "Channel Info: "
                        <|> identImg defAttr c
      MaskListFocus mode c -> string defAttr (maskListTitle mode ++ ": ")
                          <|> identImg defAttr c
      DCCFocus _ -> string defAttr "DCC progress: "

  topicbar chan =
    case preview (connChannels . ix chan . chanTopic . folded . folded . _1) conn of
      Just topic | not (Text.null topic) -> cleanText topic
      _ -> char defAttr ' '

-- | Try to drop the suggested number of elements and then
-- take the requested number of elements. If the drop drops
-- too many, drop fewer (when possible) in favor of taking
-- the correct number of elements. Return the actual number
-- of elements dropped along with the elements kept.
scrollList ::
  Int {- ^ take parameter -} ->
  Int {- ^ suggested drop -} ->
  [a] {- ^ all elements   -} ->
  (Int,[a]) {- ^ (actual drop, selected elements) -}
scrollList t d xs
  | length xs' == t = (d,xs')
  | otherwise       = (d',drop d' xs)
  where
  xs' = take t (drop d xs)
  x'len = length xs'
  d' = max 0 (d - (t - x'len))

maskListTitle :: Char -> String
maskListTitle 'b' = "Bans"
maskListTitle 'q' = "Quiets"
maskListTitle 'I' = "Invite exceptions"
maskListTitle 'e' = "Ban exceptions"
maskListTitle m   = "Unknown '" ++ [m] ++ "' masks"

textbox :: ClientState -> Image
textbox st
  = applyCrop
  $ beginning <|> content <|> ending
  where
  pos = view (clientEditBox . Edit.pos) st
  width = view clientWidth st
  (content,_) = inputLogic st
  applyCrop
    | 1+pos < width = cropRight width
    | otherwise     = cropLeft  width . cropRight (pos+2)

  beginning = char (withForeColor defAttr brightBlack) '^'
  ending    = char (withForeColor defAttr brightBlack) '$'

dividerImage :: UTCTime -> ClientState -> Image
dividerImage now st
  = extendToWidth (nickPart <|> channelPart <|> lagPart)
  where
  conn = view (clientServer0 . ccConnection) st

  myNick = view connNick conn

  drawLagTime color s =
       let s' = realToFrac s :: Centi -- truncate to two decimal places
           sStr = showFixed True s' <> "s"
       in
                string defAttr "-["
            <|> string (withForeColor defAttr color) sStr
            <|> string defAttr "]"

  lagPart =
    case view connPingTime conn of
      NoPing        -> emptyImage
      PingSent when -> drawLagTime red (realToFrac (diffUTCTime now when))
      PingTime s    -> drawLagTime yellow s


  channelPart =
    ifoldr (\i x xs -> drawOne i x <|> xs)
           emptyImage
           (fullMessageLists st <> extraDefaults)

  -- e.g. glguy(+Zi)
  nickPart =
    identImg defAttr myNick <|>
    string defAttr "(+" <|>
    utf8Bytestring' defAttr (view connUmode conn) <|>
    char defAttr ')'

  drawOne :: Identifier -> MessageList -> Image
  drawOne i seen
    | focusedName st == i =
        string defAttr "─(" <|>
        string (withForeColor defAttr blue) focusedChanPrefixes <|>
        utf8Bytestring'
          (withForeColor defAttr green)
          (identToBytes i) <|>
        string defAttr ")"
    | views mlNewMessages (>0) seen =
        string defAttr "─[" <|>
        utf8Bytestring'
          (withForeColor defAttr brightBlue)
          (identToBytes i) <|>
        string defAttr ":" <|>
        string (withForeColor defAttr (seenColor seen))
               (show (view mlNewMessages seen)) <|>
        string defAttr "]"
    | otherwise =
        string defAttr "─o"

  -- e.g. [('o','@'),('v','+')]
  prefixMapping = view (connChanModeTypes . modesPrefixModes) conn
  myFocusedModes = view (connChannels . ix (focusedName st) . chanUsers . ix myNick) conn

  -- allow prefixMapping to dictate the ordering
  focusedChanPrefixes = [ prefix | (mode,prefix) <- prefixMapping, mode `elem` myFocusedModes ]

  -- deal with the fact that the server window uses the "" identifier
  identToBytes x
    | x == "" = "server"
    | otherwise = idBytes x

  seenColor :: MessageList -> Color
  seenColor seen
    | view mlMentioned seen = red
    | view mlNewMessages seen > 0 = green
    | otherwise = brightBlack

  extendToWidth img =
    img <|> string defAttr (replicate (view clientWidth st - imageWidth img) '─')

  extraDefaults =
    Map.singleton (focusedName st) defaultMessageList

------------------------------------------------------------------------
-- Event loops
------------------------------------------------------------------------

sendLoop :: IORef Bool -> TChan ByteString -> Connection -> IO ()
sendLoop connectedRef queue h =
  do r <- newRateLimitDefault
     forever $
       do x <- atomically (readTChan queue)
          tickRateLimit r
          connectionPut h x
  `catch` \(SomeException _) ->
      writeIORef connectedRef False -- exit silently

socketLoop :: TChan (UTCTime, MsgFromServer) -> Connection -> Maybe Handle -> IO ()
socketLoop chan h hErr =
  forever (atomically . writeTChan chan =<< getOne h hErr)
  `catches`
   [ Handler $ \ioe ->
      do let msg = if isEOFError ioe
                    then "Connection terminated"
                    else Text.encodeUtf8 (Text.pack (show ioe))
         now <- getCurrentTime
         atomically (writeTChan chan (now, Error msg))
   , Handler $ \(SomeException e) ->
        do now <- getCurrentTime
           atomically (writeTChan chan (now, Error (Text.encodeUtf8 (Text.pack (show e)))))
   ]

vtyEventLoop :: TChan Event -> Vty -> IO a
vtyEventLoop chan vty = forever (atomically . writeTChan chan =<< nextEvent vty)

getOne :: Connection -> Maybe Handle -> IO (UTCTime, MsgFromServer)
getOne h hErr =
    do xs <- getRawIrcLine h
       case parseRawIrcMsg xs of
         _ | B.null xs -> connectionClosed
         Nothing       -> unparsableLine xs
         Just rawMsg   ->
           do t <- maybe getCurrentTime return (msgTime rawMsg)
              case ircMsgToServerMsg rawMsg of
                Nothing -> unhandledMsg t rawMsg
                Just msg -> handledMsg t msg
  where
  debugPrint x = for_ hErr (`hPrint` x)

  connectionClosed =
    do t <- getCurrentTime
       return (t,Error "Connection closed")

  unparsableLine xs =
    do debugPrint xs
       t <- getCurrentTime
       return (t,Error ("Unparsable IRC line: " <> xs))

  unhandledMsg t rawMsg =
    do debugPrint rawMsg
       return (t,Error ("Unhandled IRC line: " <> Text.encodeUtf8 (Text.pack (show rawMsg))))

  handledMsg t msg =
    do debugPrint msg
       return (t,msg)

readEitherTChan :: TChan a -> TChan b -> IO (Either a b)
readEitherTChan a b =
  atomically (fmap Left (readTChan a) `orElse` fmap Right (readTChan b))

------------------------------------------------------------------------
-- Tab completion logic
------------------------------------------------------------------------

tabComplete :: ClientState -> ClientState
tabComplete st = fromMaybe st $
  do let current = currentWord st
     guard (not (null current))
     c <- focusedChan st
     let vals = userSet c <> channelSet
     case view clientTabPattern st of
       Just pat -> do next <- tabSearch pat current vals
                      Just $ replaceWith next st

       Nothing  -> do next <- tabSearch current current vals
                      Just $ set clientTabPattern (Just current)
                           $ replaceWith next st
  where
  conn = view (clientServer0 . ccConnection) st

  replaceWith str = over clientEditBox $ \box ->
    let box1 = Edit.killWord False box
        str1 | view Edit.pos box1 == 0 = str ++ ": "
             | otherwise               = str
    in Edit.insertString str1 box1

  userSet c  = views (connChannels . ix c . chanUsers) Map.keysSet conn
  channelSet = views connChannels                      Map.keysSet conn

currentWord :: ClientState -> String
currentWord st
  = reverse
  $ takeWhile (not . isSpace)
  $ dropWhile (\x -> x==' ' || x==':')
  $ reverse
  $ take (view (clientEditBox . Edit.pos) st) (clientInput st)

tabSearch :: String -> String -> Set Identifier -> Maybe String
tabSearch pat cur vals
  | Just next <- Set.lookupGT cur' vals
  , B.isPrefixOf (idDenote pat') (idDenote next)
  = Just (B8.unpack (idBytes next))

  -- wrap around when pat is a user
  | Just next <- Set.lookupGE pat' vals
  , B.isPrefixOf (idDenote pat') (idDenote next)
  = Just (B8.unpack (idBytes next)) -- TODO: Use original case

  -- if all else fails, do nothing
  | otherwise = Nothing
  where
  pat' = mkId (B8.pack pat)
  cur' = mkId (B8.pack cur)

defaultNickColors :: [Color]
defaultNickColors =
  [cyan, magenta, green, yellow, blue,
   brightCyan, brightMagenta, brightGreen, brightBlue]

schedulePing :: ClientState -> IO ClientState
schedulePing st =
  do now <- getCurrentTime
     let pingTime = addUTCTime 60 now
     return (addTimerEvent pingTime TransmitPing st)

updatePingTime :: ClientState -> IO ClientState
updatePingTime st =
  do now <- getCurrentTime
     return $! set (clientServer0.ccConnection.connPingTime) (PingSent now) st
