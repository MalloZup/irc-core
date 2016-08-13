{-|
Module      : Client.CApi
Description : Dynamically loaded extension API
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

-}
module Client.CApi
  ( ActiveExtension
  , activateExtension
  , deactivateExtension
  , notifyExtensions
  ) where

import           Client.CApi.Types
import           Client.ConnectionState
import           Control.Exception
import           Control.Lens
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Cont
import           Data.Foldable
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Foreign as Text
import           Foreign.Marshal
import           Foreign.Ptr
import           Foreign.StablePtr
import           Foreign.Storable
import           Irc.RawIrcMsg
import           Irc.UserInfo
import           System.Posix.DynamicLinker

-- | The symbol that is loaded from an extension object. It is
-- expected to have the type @struct galua_extension@.
extensionSymbol :: String
extensionSymbol = "extension"

data ActiveExtension = ActiveExtension
  { aeFgn     :: FgnExtension -- ^ Struct of callback function pointers
  , aeDL      :: DL           -- ^ Handle of dynamically linked extension
  , aeSession :: Ptr ()       -- ^ State value generated by start callback
  }

activateExtension :: FilePath -> IO ActiveExtension
activateExtension path =
  do dl <- dlopen path [RTLD_LAZY, RTLD_LOCAL]
     p  <- dlsym dl extensionSymbol
     md <- peek (castFunPtrToPtr p)
     let f = fgnStart md
     s  <- if nullFunPtr == f
             then return nullPtr
             else runStartExtension f
     return ActiveExtension
       { aeFgn     = md
       , aeDL      = dl
       , aeSession = s
       }

deactivateExtension :: ActiveExtension -> IO ()
deactivateExtension ae =
  do let f = fgnStop (aeFgn ae)
     unless (nullFunPtr == f)
        (runStopExtension f (aeSession ae))
     dlclose (aeDL ae)

notifyExtensions ::
  Text -> ConnectionState -> RawIrcMsg -> [ActiveExtension] -> IO ()
notifyExtensions network cs msg aes = evalContT $
  do let getFun = fgnProcess . aeFgn
         aes' = filter (\ae -> getFun ae /= nullFunPtr) aes

     contT0 $ unless $ null aes'
     msgPtr <- withRawIrcMsg network msg
     csPtr  <- withStablePtr cs
     ae     <- ContT $ for_ aes'
     lift (runProcessMessage (getFun ae) (castStablePtrToPtr csPtr) (aeSession ae) msgPtr)

withStablePtr :: a -> ContT r IO (StablePtr a)
withStablePtr x = ContT $ bracket (newStablePtr x) freeStablePtr

withRawIrcMsg ::
  Text                 {- ^ network      -} ->
  RawIrcMsg            {- ^ message      -} ->
  ContT a IO (Ptr FgnMsg)
withRawIrcMsg network msg =
  do net     <- withText network
     pfx     <- withText $ maybe Text.empty renderUserInfo $ view msgPrefix msg
     cmd     <- withText $ view msgCommand msg
     prms    <- traverse withText $ view msgParams msg
     tags    <- traverse withTag  $ view msgTags   msg
     let (keys,vals) = unzip tags
     (tagN,keysPtr) <- contT2 $ withArrayLen keys
     valsPtr        <- ContT  $ withArray vals
     (prmN,prmPtr)  <- contT2 $ withArrayLen prms
     ContT $ with $ FgnMsg net pfx cmd prmPtr (fromIntegral prmN)
                                       keysPtr valsPtr (fromIntegral tagN)

withTag :: TagEntry -> ContT a IO (FgnStringLen, FgnStringLen)
withTag (TagEntry k v) =
  do pk <- withText k
     pv <- withText v
     return (pk,pv)

withText :: Text -> ContT a IO FgnStringLen
withText txt =
  do (ptr,len) <- ContT $ Text.withCStringLen txt
     return $ FgnStringLen ptr $ fromIntegral len

contT0 :: (m a -> m a) -> ContT a m ()
contT0 f = ContT $ \g -> f $ g ()

contT2 :: ((a -> b -> m c) -> m c) -> ContT c m (a,b)
contT2 f = ContT $ f . curry