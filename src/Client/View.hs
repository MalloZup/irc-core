{-# Language BangPatterns #-}
{-|
Module      : Client.View
Description : View selection module
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module selects the correct view based on the current state.

-}
module Client.View
  ( viewLines
  , viewSubfocusLabel
  ) where

import           Client.Image.Palette
import           Client.State
import           Client.State.Focus
import           Client.View.ChannelInfo
import           Client.View.Help
import           Client.View.MaskList
import           Client.View.Mentions
import           Client.View.Messages
import           Client.View.Palette
import           Client.View.UserList
import           Client.View.Windows
import           Control.Lens
import           Graphics.Vty.Image

viewLines :: Focus -> Subfocus -> ClientState -> [Image]
viewLines focus subfocus !st =
  case (focus, subfocus) of
    (ChannelFocus network channel, FocusInfo) ->
      channelInfoImages network channel st
    (ChannelFocus network channel, FocusUsers)
      | view clientDetailView st -> userInfoImages network channel st
      | otherwise                -> userListImages network channel st
    (ChannelFocus network channel, FocusMasks mode) ->
      maskListImages mode network channel st
    (_, FocusWindows) -> windowsImages st
    (_, FocusMentions) -> mentionsViewLines st
    (_, FocusPalette) -> paletteViewLines pal
    (_, FocusHelp mb) -> helpImageLines mb pal

    _ -> chatMessageImages focus st
  where
    pal = clientPalette st

viewSubfocusLabel :: Palette -> Subfocus -> Maybe Image
viewSubfocusLabel pal subfocus =
  case subfocus of
    FocusMessages -> Nothing
    FocusWindows  -> Just $ string (view palLabel pal) "windows"
    FocusInfo     -> Just $ string (view palLabel pal) "info"
    FocusUsers    -> Just $ string (view palLabel pal) "users"
    FocusMentions -> Just $ string (view palLabel pal) "mentions"
    FocusPalette  -> Just $ string (view palLabel pal) "palette"
    FocusHelp mb  -> Just $ string (view palLabel pal) "help" <|>
                            foldMap (\cmd -> char defAttr ':' <|>
                                        text' (view palLabel pal) cmd) mb
    FocusMasks m  -> Just $ horizCat
      [ string (view palLabel pal) "masks"
      , char defAttr ':'
      , char (view palLabel pal) m
      ]