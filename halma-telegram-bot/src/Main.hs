{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module Main where

import Game.Halma.Board
import Game.Halma.Configuration
import Game.Halma.TelegramBot.BotM
import Game.Halma.TelegramBot.Cmd
import Game.Halma.TelegramBot.DrawBoard
import Game.Halma.TelegramBot.I18n
import Game.Halma.TelegramBot.Move
import Game.Halma.TelegramBot.Types
import Game.TurnCounter
import qualified Game.Halma.AI.Ignorant as IgnorantAI
import qualified Game.Halma.AI.Competitive as CompetitiveAI

import Control.Concurrent (threadDelay)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.State.Class (MonadState (..), gets, modify)
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Servant.Common.Req (ServantError)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Web.Telegram.API.Bot as TG

main :: IO ()
main =
  getArgs >>= \case
    "--help":_ -> usage
    "-h":_ -> usage
    [tokenStr] -> do
      manager <- newManager tlsManagerSettings
      let
        cfg =  
          BotConfig
            { bcToken = TG.Token (ensureIsPrefixOf "bot" (T.pack tokenStr))
            , bcManager = manager
            }
      evalGlobalBotM halmaBot cfg
    _ -> usage
  where
    usage = hPutStrLn stderr "Usage: ./halma-bot telegram-token"

ensureIsPrefixOf :: T.Text -> T.Text -> T.Text
ensureIsPrefixOf prefix str =
  if prefix `T.isPrefixOf` str then str else prefix <> str

mkButton :: T.Text -> TG.KeyboardButton
mkButton text =
  TG.KeyboardButton
    { TG.kb_text = text
    , TG.kb_request_contact = Nothing
    , TG.kb_request_location = Nothing
    }

mkKeyboard :: [[T.Text]] -> TG.ReplyKeyboard
mkKeyboard buttonLabels =
  TG.ReplyKeyboardMarkup
    { TG.reply_keyboard = fmap mkButton <$> buttonLabels
    , TG.reply_resize_keyboard = Just True
    , TG.reply_one_time_keyboard = Just True
    , TG.reply_selective = Just False
    }

textMsgWithKeyboard :: T.Text -> TG.ReplyKeyboard -> Msg
textMsgWithKeyboard text keyboard chatId =
  (TG.sendMessageRequest (T.pack (show chatId)) text)
  { TG.message_reply_markup = Just keyboard }

getUpdates :: GlobalBotM (Either ServantError [TG.Update])
getUpdates = do
  nid <- gets bsNextId
  let
    limit = 100
    timeout = 10
    updateReq token =
      TG.getUpdates token (Just nid) (Just limit) (Just timeout)
  runReq updateReq >>= \case
    Left err -> return (Left err)
    Right (TG.UpdatesResponse updates) -> do
      unless (null updates) $ do
        let nid' = 1 + maximum (map TG.update_id updates)
        modify (\s -> s { bsNextId = nid' })
      return (Right updates)

getUpdatesRetry :: GlobalBotM [TG.Update]
getUpdatesRetry =
  getUpdates >>= \case
    Left err -> do
      printError err
      liftIO $ threadDelay 1000000 -- wait one second
      getUpdatesRetry
    Right updates -> pure updates

sendCurrentBoard :: HalmaState -> BotM ()
sendCurrentBoard halmaState =
  withRenderedBoardInPngFile halmaState mempty $ \path -> do
    chatId <- gets hcId
    let
      fileUpload = TG.localFileUpload path
      photoReq = TG.uploadPhotoRequest (T.pack (show chatId)) fileUpload
    logErrors $ runReq $ \token -> TG.uploadPhoto token photoReq

handleCommand :: CmdCall -> BotM (Maybe (BotM ()))
handleCommand cmdCall =
  case cmdCall of
    CmdCall { cmdCallName = "help" } -> do
      sendI18nMsg hlHelpMsg
      pure Nothing
    CmdCall { cmdCallName = "start" } ->
      pure $ Just $ do
        modify $ \chat ->
          chat { hcMatchState = NoMatch }
        sendI18nMsg hlWelcomeMsg
    CmdCall { cmdCallName = "setlang", cmdCallArgs = Nothing } -> do
      sendMsg $ textMsg $
        "/setlang expects an argument!"
      pure Nothing
    CmdCall { cmdCallName = "setlang", cmdCallArgs = Just arg } ->
      case parseLocaleId arg of
        Just localeId ->
          pure $ Just $
            modify $ \chat -> chat { hcLocale = localeById localeId }
        Nothing -> do
          sendMsg $ textMsg $
            "Could not parse language. Must be one of the following strings: " <>
            T.intercalate ", " (map showLocaleId allLocaleIds)
          pure Nothing
    CmdCall { cmdCallName = "newmatch" } ->
      pure $ Just $ modify $ \chat ->
        chat { hcMatchState = GatheringPlayers NoPlayers }
    CmdCall { cmdCallName = "newround" } ->
      pure $ Just $ sendMsg $ textMsg "todo: newround"
    CmdCall { cmdCallName = "undo" } -> do
      matchState <- gets hcMatchState
      case matchState of
        MatchRunning match@Match{ matchCurrentGame = Just game } ->
          case undoLastMove game of
            Just game' ->
              let
                match' = match { matchCurrentGame = Just game' }
              in
                pure $ Just $
                  modify $ \chat ->
                    chat { hcMatchState = MatchRunning match' }
            Nothing -> do
              sendMsg $ textMsg "can't undo!"
              pure Nothing
        _ -> do
          sendMsg $ textMsg
            "can't undo: there's no game running!"
          pure Nothing
    _ -> pure Nothing

sendMoveSuggestions
  :: TG.User
  -> TG.Message
  -> HalmaState
  -> NonEmpty (MoveCmd, Move)
  -> BotM ()
sendMoveSuggestions sender msg game suggestions = do
  let
    text =
      showUser sender <> ", the move command you sent is ambiguous. " <>
      "Please send another move command or choose one in the " <>
      "following list."
    suggestionToButton (moveCmd, _move) =
      showMoveCmd moveCmd
    keyboard = mkKeyboard [suggestionToButton <$> toList suggestions]
    suggestionToLabel (moveCmd, move) =
      ( moveTo move
      , maybe "" showTargetModifier (moveTargetModifier moveCmd)
      )
    boardLabels =
      M.fromList $ map suggestionToLabel $ toList suggestions
  withRenderedBoardInPngFile game boardLabels $ \path -> do
    chatId <- gets hcId
    let
      fileUpload = TG.localFileUpload path
      photoReq =
        (TG.uploadPhotoRequest (T.pack (show chatId)) fileUpload)
          { TG.photo_caption = Just text
          , TG.photo_reply_to_message_id = Just (TG.message_id msg)
          , TG.photo_reply_markup = Just keyboard
          }
    logErrors $ runReq $ \token -> TG.uploadPhoto token photoReq

handleMoveCmd
  :: Match
  -> HalmaState
  -> MoveCmd
  -> TG.Message
  -> BotM (Maybe (BotM ()))
handleMoveCmd match game moveCmd fullMsg = do
  liftIO $ putStrLn $ T.unpack $ showMoveCmd moveCmd
  case TG.from fullMsg of
    Nothing -> do
      sendMsg $ textMsg $
        "can't identify sender of move command " <> showMoveCmd moveCmd <> "!"
      pure Nothing
    Just sender -> do
      let
        currParty = currentPlayer (hsTurnCounter game)
        homeCorner = partyHomeCorner currParty
        player = partyPlayer currParty
        checkResult =
          checkMoveCmd (matchRules match) (hsBoard game) homeCorner moveCmd
      case checkResult of
        _ | player /= TelegramPlayer sender -> do
          sendMsg $ textMsg $
            "Hey " <> showUser sender <> ", it's not your turn, it's " <>
            showPlayer player <> "'s!"
          pure Nothing
        MoveImpossible reason -> do
          sendMsg $ textMsg $
            "This move is not possible: " <> T.pack reason
          pure Nothing
        MoveSuggestions suggestions -> do
          sendMoveSuggestions sender fullMsg game suggestions
          pure Nothing
        MoveFoundUnique move ->
          case doMove move game of
            Left err -> do
              printError err
              pure Nothing
            Right game' -> do
              let
                match' = match { matchCurrentGame = Just game' }
              pure $ Just $
                modify $ \chat ->
                  chat { hcMatchState = MatchRunning match' }

handleTextMsg
  :: T.Text
  -> TG.Message
  -> BotM (Maybe (BotM ()))
handleTextMsg text fullMsg = do
  matchState <- gets hcMatchState
  case (matchState, text) of
    (_, parseCmdCall -> Just cmdCall) ->
      handleCommand cmdCall
    ( MatchRunning match@Match { matchCurrentGame = Just game }, parseMoveCmd -> Right moveCmd) ->
      handleMoveCmd match game moveCmd fullMsg
    (GatheringPlayers players, "me") ->
      pure $ Just (addTelegramPlayer players)
    (GatheringPlayers players, "yes, me") ->
      pure $ Just (addTelegramPlayer players)
    (GatheringPlayers players, "an AI") ->
      pure $ Just (addAIPlayer players)
    (GatheringPlayers players, "yes, an AI") ->
      pure $ Just (addAIPlayer players)
    (GatheringPlayers (EnoughPlayers config), "no") ->
      pure $ Just (startMatch config)
    _ -> pure Nothing
  where
    addPlayer :: Player -> PlayersSoFar Player -> BotM ()
    addPlayer new playersSoFar = do
      playersSoFar' <-
        case playersSoFar of
          NoPlayers ->
            pure $ OnePlayer new
          OnePlayer a ->
            case configuration SmallGrid (TwoPlayers a new) of
              Just config -> pure $ EnoughPlayers config
              Nothing -> fail "could not create configuration with two players and small grid!"
          EnoughPlayers config ->
            pure $ EnoughPlayers (addPlayerToConfig new config)
      chat <- get
      case playersSoFar' of
        EnoughPlayers config@(configurationPlayers -> SixPlayers{}) ->
          put $ chat { hcMatchState = MatchRunning (newMatch config) }
        _ ->
          put $ chat { hcMatchState = GatheringPlayers playersSoFar' }
    addAIPlayer :: PlayersSoFar Player -> BotM ()
    addAIPlayer = addPlayer AIPlayer
    addTelegramPlayer :: PlayersSoFar Player -> BotM ()
    addTelegramPlayer players =
      case TG.from fullMsg of
        Nothing ->
          sendMsg $ textMsg "cannot add sender of last message as a player!"
        Just user ->
          addPlayer (TelegramPlayer user) players
    startMatch players =
      modify $ \chat ->
        chat { hcMatchState = MatchRunning (newMatch players) }

sendI18nMsg :: (HalmaLocale -> T.Text) -> BotM ()
sendI18nMsg getText = do
  text <- translate getText
  sendMsg $ textMsg text -- todo: url link suppression

sendGatheringPlayers :: PlayersSoFar Player -> BotM ()
sendGatheringPlayers playersSoFar =
  case playersSoFar of
    NoPlayers ->
      sendMsg $ textMsgWithKeyboard
        "Starting a new match! Who is the first player?"
        meKeyboard
    OnePlayer firstPlayer ->
      let
        text =
          "The first player is " <> showPlayer firstPlayer <> ".\n" <>
          "Who is the second player?"
      in
        sendMsg (textMsgWithKeyboard text meKeyboard)
    EnoughPlayers config -> do
      (count, nextOrdinal) <-
        case configurationPlayers config of
          TwoPlayers {}   -> pure ("two", "third")
          ThreePlayers {} -> pure ("three", "fourth")
          FourPlayers {}  -> pure ("four", "fifth")
          FivePlayers {}  -> pure ("five", "sixth")
          SixPlayers {} ->
            fail "unexpected state: gathering players although there are already six!"
      let
        text =
          "The first " <> count <> " players are " <>
          prettyList (map showPlayer (toList (configurationPlayers config))) <> ".\n" <>
          "Is there a " <> nextOrdinal <> " player?"
      sendMsg (textMsgWithKeyboard text anotherPlayerKeyboard)
  where
    prettyList :: [T.Text] -> T.Text
    prettyList xs =
      case xs of
        [] -> "<empty list>"
        [x] -> x
        _ -> T.intercalate ", " (init xs) <> " and " <> last xs
    meKeyboard = mkKeyboard [["me"], ["an AI"]]
    anotherPlayerKeyboard =
      mkKeyboard [["yes, me"], ["yes, an AI"], ["no"]]

teamEmoji :: Team -> T.Text
teamEmoji dir =
  case dir of
    North     -> "\128309" -- :large_blue_circle: for blue
    Northeast -> "\128154" -- :green_heart: for green
    Northwest -> "\128156" -- :purple_heart: for purple
    South     -> "\128308" -- :red_circle: for red
    Southeast -> "\9899"   -- :medium_black_circle: for black
    Southwest -> "\128310" -- :large_orange_diamond: for orange

doAIMove :: Match -> HalmaState -> BotM ()
doAIMove match game = do
  let
    tc = hsTurnCounter game
    board = hsBoard game
    rules = matchRules match
    numberOfPlayers = length $ tcPlayers tc
    currParty = currentPlayer tc
    aiMove =
      if numberOfPlayers == 2 then
        let
          nextParty = nextPlayer tc
          perspective = (partyHomeCorner currParty, partyHomeCorner nextParty)
        in
          CompetitiveAI.aiMove rules board perspective
      else
        IgnorantAI.aiMove rules board (partyHomeCorner currParty)
    mAIMoveCmd = moveToMoveCmd rules board aiMove
  case doMove aiMove game of
    Left err ->
      fail $ "doing an AI move failed unexpectedly: " ++ err
    Right game' -> do
      let match' = match { matchCurrentGame = Just game' }
      case mAIMoveCmd of
        Just moveCmd ->
          sendMsg $ textMsg $
            "The AI " <> teamEmoji (partyHomeCorner currParty) <>
            " makes the following move: " <> showMoveCmd moveCmd
        Nothing -> pure ()
      modify $ \chat ->
        chat { hcMatchState = MatchRunning match' }

sendGameState :: Match -> HalmaState -> BotM ()
sendGameState match game = do
  sendCurrentBoard game
  let
    currParty = currentPlayer (hsTurnCounter game)
    unicodeSymbol = teamEmoji (partyHomeCorner currParty)
  case partyPlayer currParty of
    AIPlayer -> do
      doAIMove match game
      sendMatchState
    TelegramPlayer user ->
      sendMsg $ textMsg $
        showUser user <> " " <> unicodeSymbol <> " it's your turn!"

sendMatchState :: BotM ()
sendMatchState = do
  matchState <- gets hcMatchState
  case matchState of
    NoMatch ->
      sendMsg $ textMsg
        "Start a new Halma match with /newmatch"
    GatheringPlayers players ->
      sendGatheringPlayers players
    MatchRunning match ->
      case matchCurrentGame match of
        Nothing ->
          sendMsg $ textMsg
            "Start a new round with /newround"
        Just game -> sendGameState match game

loadHalmaChat :: ChatId -> GlobalBotM HalmaChat
loadHalmaChat chatId = do
  chats <- gets bsChats
  case M.lookup chatId chats of
    Nothing -> pure (initialHalmaChat chatId)
    Just chat -> pure chat

saveHalmaChat :: HalmaChat -> GlobalBotM ()
saveHalmaChat chat = 
  modify $ \botState ->
    let
      chats = bsChats botState
      chats' = M.insert (hcId chat) chat chats
    in
      botState { bsChats = chats' }

withHalmaChat
  :: ChatId
  -> BotM a
  -> GlobalBotM a
withHalmaChat chatId action = do
  chat <- loadHalmaChat chatId
  (res, chat') <- stateZoom chat action
  saveHalmaChat chat'
  return res

handleUpdate
  :: TG.Update
  -> GlobalBotM ()
handleUpdate update = do
  liftIO $ print update
  case update of
    TG.Update { TG.message = Just msg } -> handleMsg msg
    _ -> return ()
  where
    handleMsg msg =
      case msg of
        TG.Message { TG.text = Just txt, TG.chat = tgChat } ->
          withHalmaChat (TG.chat_id tgChat) $ do
            handleTextMsg txt msg >>= \case
              Nothing -> return ()
              Just action -> do
                action
                sendMatchState
        _ -> return ()

halmaBot :: GlobalBotM ()
halmaBot = do
  updates <- getUpdatesRetry
  mapM_ handleUpdate updates
  halmaBot