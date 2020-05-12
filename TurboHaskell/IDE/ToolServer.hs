module TurboHaskell.IDE.ToolServer where

import TurboHaskell.Prelude
import qualified Network.HTTP.Types as Http
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.WebSockets as Websocket
import qualified Network.Wai.Handler.WebSockets as Websocket
import qualified Control.Concurrent as Concurrent
import TurboHaskell.HaskellSupport
import qualified Text.Blaze.Html.Renderer.Utf8 as Blaze
import qualified Network.HTTP.Types.Header as HTTP
import qualified Text.Blaze.Html5 as Html5
import qualified Network.HTTP.Types as HTTP
import qualified Data.ByteString.Char8 as ByteString
import TurboHaskell.IDE.Types
import TurboHaskell.IDE.PortConfig
import qualified TurboHaskell.ControllerSupport as ControllerSupport
import qualified TurboHaskell.ErrorController as ErrorController
import TurboHaskell.ApplicationContext
import TurboHaskell.ModelSupport
import TurboHaskell.RouterSupport hiding (get)
import qualified Web.Cookie as Cookie
import Network.Wai.Session.Map (mapStore_)
import qualified Data.Time.Clock
import Network.Wai.Session.ClientSession (clientsessionStore)
import qualified Web.ClientSession as ClientSession
import qualified Data.Vault.Lazy as Vault
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import Network.Wai.Middleware.MethodOverridePost (methodOverridePost)
import Network.Wai.Middleware.Static
import Network.Wai.Session (withSession, Session)

import TurboHaskell.IDE.SchemaDesigner.Types
import TurboHaskell.IDE.SchemaDesigner.Controller.EnumValues
import TurboHaskell.IDE.SchemaDesigner.Controller.Enums
import TurboHaskell.IDE.SchemaDesigner.Controller.Columns
import TurboHaskell.IDE.SchemaDesigner.Controller.Schema
import TurboHaskell.IDE.SchemaDesigner.Controller.Tables
import TurboHaskell.IDE.Data.Controller

import TurboHaskell.IDE.Logs.Controller


import TurboHaskell.IDE.ToolServer.Types
import Control.Concurrent.Async
import TurboHaskell.IDE.ToolServer.Routes
import qualified System.Process as Process
import System.Info

startToolServer :: (?context :: Context) => IO ()
startToolServer = do
    let port = ?context
            |> get #portConfig
            |> get #toolServerPort
            |> fromIntegral



    thread <- async (startToolServer' port)

    openUrl ("http://localhost:" <> tshow port <> "/turbohaskell/")

    dispatch (UpdateToolServerState (ToolServerStarted { thread }))
    
startToolServer' port = do
    session <- Vault.newKey
    store <- case os of
        "linux" -> mapStore_
        _ -> fmap clientsessionStore (ClientSession.getKey "Config/client_session_key.aes")
    let sessionCookie = def
                { Cookie.setCookiePath = Just "/"
                , Cookie.setCookieMaxAge = Just (fromIntegral (60 * 60 * 24 * 30))
                , Cookie.setCookieSameSite = Just Cookie.sameSiteLax
                }
    let sessionMiddleware :: Wai.Middleware = withSession store "SESSION" sessionCookie session    
    let applicationContext = ApplicationContext { modelContext = (ModelContext (error "Not connected")), session }
    let toolServerApplication = ToolServerApplication { devServerContext = ?context }
    let application :: Wai.Application = \request respond -> do
            let ?applicationContext = applicationContext
            requestContext <- ControllerSupport.createRequestContext applicationContext request respond
            let ?requestContext = requestContext
            frontControllerToWAIApp toolServerApplication ErrorController.handleNotFound
            
    let staticMiddleware :: Wai.Middleware = staticPolicy (addBase "TurboHaskell/TurboHaskell/static/")

    let warpSettings = Warp.defaultSettings |> Warp.setPort port
    
    Warp.runSettings warpSettings $ 
            staticMiddleware $ logStdoutDev $ methodOverridePost $ sessionMiddleware $ application

stopToolServer ToolServerStarted { thread } = uninterruptibleCancel thread
stopToolServer ToolServerNotStarted = pure ()

openUrl :: Text -> IO ()
openUrl url = do
    when (os /= "linux") $ Process.callCommand (cs $ "open " <> url)
    pure ()

instance FrontController ToolServerApplication where
    controllers =
        [ parseRoute @SchemaController
        , parseRoute @TablesController
        , parseRoute @ColumnsController
        , parseRoute @EnumsController
        , parseRoute @EnumValuesController
        , parseRoute @LogsController
        , parseRoute @DataController
        , catchAll TablesAction
        ]

instance ControllerSupport.InitControllerContext ToolServerApplication where