{-# Language TemplateHaskell #-}
module Client.Message where

import           Control.Lens
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Time (ZonedTime)
import           Irc.Message

data MessageBody = IrcBody !IrcMsg | ErrorBody !String | ExitBody

makePrisms ''MessageBody

data ClientMessage = ClientMessage
  { _msgNetwork :: !Text
  , _msgBody    :: !MessageBody
  , _msgTime    :: !ZonedTime
  }

makeLenses ''ClientMessage

msgText :: MessageBody -> Text
msgText (IrcBody irc) = ircMsgText irc
msgText (ErrorBody str) = Text.pack str
msgText ExitBody = Text.empty
