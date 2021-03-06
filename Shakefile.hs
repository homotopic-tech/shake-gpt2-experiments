{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

import           Control.Comonad
import           Control.Lens hiding (view)
import           Data.Aeson.Lens
import           Data.List.Split hiding (oneOf)
import qualified Data.Yaml as Yaml
import           RIO hiding (some, try, many)
import qualified RIO.ByteString as BS
import qualified RIO.ByteString.Lazy as LBS
import qualified RIO.HashMap as HM
import           RIO.List
import           RIO.Partial
import           RIO.List.Partial
import qualified RIO.Set             as S
import qualified RIO.Text            as T
import qualified RIO.Text.Partial
import           RIO.State
import           Shakebook
import           Text.Megaparsec
import           Text.Megaparsec.Char
import           Text.Megaparsec.Char.Lexer
import           Text.Pandoc.Readers
import           Text.Pandoc.Definition
import           Text.Pandoc.Options
import           Text.Pandoc.Class
import           Text.Pandoc.Writers
import qualified Control.Exception as EUnsafe
import Control.Monad.Catch hiding (try)
import           Text.Pandoc.Walk

outputFolder = $(mkRelFile "out")

myMDWriterOptions :: WriterOptions
myMDWriterOptions = def { writerExtensions = pandocExtensions }
--myMDWriterOptions = def

type Parser = Parsec Void Text

squiggles :: Parser a -> Parser a
squiggles = between (string "{{") (string "}}")

data Affiliation = Alliance | Horde | Neutral | Hostile
  deriving (Eq, Show, Read, Ord, Enum)

data NPC = NPC {
  npcAffiliation :: Affiliation
, npcName        :: Text
, npcRole        :: Maybe Text
, npcIcon        :: Text
} deriving (Eq, Show, Ord)

mediafield :: Parser Text
mediafield = T.pack <$> many (alphaNumChar <|> spaceChar <|> char '\'' <|> char '"' <|> char '\"' <|> char '-' <|> char '.' <|> char ',' <|> char '?' <|> char '!')

npc :: Parser NPC
npc = squiggles $ do
  void $ string "NPC" >> char '|'
  npcAffiliation <- affiliation
  void $ char '|'
  npcName <- mediafield
  void $ char '|'
  npcRole <- optional . try $ do 
    a <- mediafield
    void $ char '|'
    return a
  void $ optional . try $ mediafield >> char '|'
  npcIcon <- iconmwfield
  return NPC{..}

affiliation :: Parser Affiliation
affiliation = choice [
   Alliance <$ string "Alliance"
 , Horde    <$ string "Horde"
 , Neutral  <$ string "Neutral"
 , Hostile  <$ string "combat"
 ]

data Illocution = Say | Yell | Emote
  deriving (Eq, Show, Ord, Enum, Read)

illocution :: Parser Illocution
illocution = choice [
   Say  <$ string "say"
 , Yell <$ string "yell"
 , Emote <$ string "emote"
 ]

data Quote = Quote {
  quoteIllocution :: Illocution
, quoteText       :: Text
} deriving (Eq, Show, Ord)

quote :: Parser Quote
quote = squiggles $ do
  void $ choice [string "text", string "Text"] >> char '|'
  quoteIllocution <- illocution
  void $ char '|'
  quoteText <- mediafield
  return Quote{..}

data Ability = Ability {
  abilityName :: Text
, abilityEffect :: Text
} deriving (Eq, Show, Ord)

ability :: Parser Ability
ability = squiggles $ do
  void $ choice [string "abilities", string "Abilities"] >> char '|'
  abilityName <- mediafield
  void $ char '|'
  abilityEffect <- mediafield
  return Ability{..}

iconmwfield :: Parser Text
iconmwfield = void (string "icon=") >> mediafield

authormwfield :: Parser Text
authormwfield = void (string "author=") >> mediafield

titlemwfield :: Parser Text
titlemwfield = void (string "title=") >> mediafield

publishermwfield :: Parser Text
publishermwfield = void (string "publisher=") >> mediafield

yearmwfield :: Parser Text
yearmwfield = void (string "year=") >> mediafield

isbnmwfield :: Parser Text
isbnmwfield = void (string "isbn=") >> mediafield

data CiteBook = CiteBook {
  cbAuthor :: Text
, cbTitle :: Text
, cbPublisher :: Text
, cbYear :: Text
, cbISBN :: Text
} deriving (Eq, Show, Ord)

viewCmTitles = toListOf (key "query" . key "categorymembers" . values . key "title" . _String)

testNPC1 = "{{NPC|Neutral|Lovely|Happy Holaua's Companion|icon=MonkeyKing}}"
testNPC2 = "{{NPC|Horde|Enforcer Dakanji|icon=Zandalari Male}}"
testNPC3 = "{{NPC|Horde|Rastakhan||King Rastakhan|icon=Rastakhan}}"
testNPC4 = "{{NPC|Neutral|Gluk-Gluk|Innkeeper|icon=Hozen}}"

-- | Pandoc filter - strip all links and replace with raw link text.
stripLinks :: [Inline] -> [Inline]
stripLinks ((Link _ txt _) : xs) = txt <> stripLinks xs
stripLinks (x : xs)             = x : stripLinks xs
stripLinks []                   = []

-- | Pandoc filter - delete all images.
deleteImages :: [Inline] -> [Inline]
deleteImages ((Image _ _ _ ) : xs) = deleteImages xs
deleteImages (x : xs)              = x : deleteImages xs
deleteImages []                    = []

-- | Pandoc filter - delete all notes.
deleteNotes :: [Inline] -> [Inline]
deleteNotes ((Note _) : xs) = deleteNotes xs
deleteNotes (x : xs)        = x : deleteNotes xs
deleteNotes []              = []

-- | Pandoc filter - delete all citations.
deleteCites :: [Inline] -> [Inline]
deleteCites ((Cite _ _) : xs) = deleteCites xs
deleteCites (x : xs)          = x : deleteCites xs
deleteCites []                = []

junkSections = [ [Str "External", Space, Str "links"]
               , [Str "Fan art"]
               , [Str "Gallery"]
               , [Str "References"]
               , [Str "Patch", Space, Str "changes"]
               , [Str "See", Space, Str "also"]
               , [Str "Videos"]
               ]

isHeader :: Block -> Bool
isHeader (Header _ _ _) = True
isHeader _ = False

splitSections :: [Block] -> [[Block]]
splitSections = split (keepDelimsL $ whenElt isHeader)

isJunkHeader :: Block -> Bool
isJunkHeader (Header _ _ a') = elem a' junkSections
isJunkHeader _ = False

isJunkSection :: [Block] -> Bool
isJunkSection (x : xs) = isJunkHeader x
isJunkSection [] = True

stripJunkSections :: [Block] -> [Block]
stripJunkSections = join . filter (not . isJunkSection) . splitSections 

stripDataBlocks :: [Inline] -> [Inline]
stripDataBlocks t@((Str x) : xs) = if "{{#data:" `T.isPrefixOf` x then [] else t
stripDataBlocks a = a

npcToPandoc :: NPC -> [Inline]
npcToPandoc NPC{..} = [Str npcName, Space] ++ (maybe [] (\k -> [Str "-", Space, Str k]) npcRole)

quoteToPandoc :: Quote -> [Inline]
quoteToPandoc Quote{..} = [Str quoteText]

abilityToPandoc :: Ability -> [Inline]
abilityToPandoc Ability{..} = [Str $ abilityName <> "-" <> abilityEffect]

convertNPCs :: [Block] -> [Block]
convertNPCs t@(x@(RawBlock b k) : xs) = (maybe x (Plain . npcToPandoc) $ parseMaybe npc k) : xs
convertNPCs a = a

convertQuotes :: [Block] -> [Block]
convertQuotes t@(x@(RawBlock b k) : xs) = (maybe x (Plain . quoteToPandoc) $ parseMaybe quote k) : xs
convertQuotes a = a

convertAbilities :: [Block] -> [Block]
convertAbilities t@(x@(RawBlock b k) : xs) = (maybe x (Plain . abilityToPandoc) $ parseMaybe ability k) : xs
convertAbilities a = a

stripRawInline :: [Inline] -> [Inline]
stripRawInline t@((RawInline _ _) : xs) = stripRawInline xs
stripRawInline x = x

stripRawBlock :: [Block] -> [Block]
stripRawBlock t@((RawBlock _ _) : xs) = stripRawBlock xs
stripRawBlock x = x

onlyParaBlocks :: [Block] -> [Block]
onlyParaBlocks t@(x@(Para _) : xs) = x : onlyParaBlocks xs
onlyParaBlocks (x : xs)  = onlyParaBlocks xs
onlyParaBlocks []        = []

data ApiType = ApiType1 | ApiType2
  deriving (Eq, Show, Generic)

instance FromJSON ApiType
instance ToJSON ApiType

data WikiManifest = WikiManifest {
  api               :: Text
, apiType           :: ApiType
, includeCategories :: [Text]
, includePages      :: [Text]
} deriving (Eq, Show, Generic)

instance FromJSON WikiManifest
instance ToJSON WikiManifest

apiType1 :: Value -> Text
apiType1 = view (key "query"
               . key "pages" . values
               . key "revisions" . values
               . key "slots" 
               . key "main"
               . key "content" . _String)

apiType2 :: Value -> Text
apiType2 = view (_String) . fromJust . HM.lookup "*" . view (_Object) . head . toListOf (key "revisions" . values) . head . HM.elems . view (key "query" . key "pages" . _Object)
 
switchContent ApiType1 = apiType1
switchContent ApiType2 = apiType2

recCollectP :: (MonadUnliftAction m, Ord a) => (a -> m (Set a)) -> Set a -> a -> m (Set a)
recCollectP g exs x = do
  x' <- g x
  xs' <- flip forP (recCollectP g (S.union exs x')) (toList $ S.filter (not . (`S.member` exs)) x')
  return $ foldr S.union (S.union (S.singleton x) x') xs'

main :: IO ()
main = runSimpleShakePlus $ do

  jsonLookup <- addRemoteJSONOracleCache

  readYaml <- newCache $ \src -> Yaml.decodeThrow =<< BS.readFile (toFilePath $ src)

  let pullJson :: Text -> RAction LogFunc Value
      pullJson x = do
       logInfo $ displayShow $ "Polling " <> x
       k <- jsonLookup . RemoteJSONLookup $ x
       logDebug $ displayShow $ "Receieved: " <> (T.pack $ show k)
       return k

  let subcatRequest u a x = pullJson $ "https://" <> u <> "/" <> a <> "?action=query&list=categorymembers&cmtitle=" <> x <> "&cmlimit=500&cmtype=subcat&format=json"
  let pagesRequest u a x = pullJson $ "https://" <> u <> "/" <> a <> "?action=query&list=categorymembers&cmtitle=" <> x <> "&cmlimit=500&cmtype=page&format=json"
  let contentRequest u a x = pullJson $ "https://" <> u <> "/" <> a <> "?action=query&prop=revisions&titles=" <> x <> "&rvslots=*&rvprop=content&formatversion=2&format=json"

      recSubcats u a x = recCollectP (fmap (S.fromList . viewCmTitles) . subcatRequest u a) mempty x

  "out/trainingset.txt" %> \out -> do
    xs  <- getDirectoryFiles $(mkRelDir ".") ["processed/markdown//*.md"]
    xs' <- forM xs $ (evaluate <=< readFile')
    let ys = map (T.unlines . (\x -> ["<|startoftext|>"] ++ T.lines x ++ ["<|endoftext|>"])) xs'
    writeFile' out $ T.unlines ys

  "raw/mediawiki/*/*.mediawiki" %> \out -> do
      let k = T.pack . (!! 2) . splitOn "/" . toFilePath$ out
      k' <- parseRelFile (T.unpack k)
      let (src :: Path Rel File) = $(mkRelDir "manifests/derived") </> k'
      needP [src]
      (WikiManifest{..}) <- readYaml src
      (x, _) <- splitExtension . filename $ out
      y <- contentRequest k api (T.pack . toFilePath $ x)
      let (y' :: Text) = switchContent apiType y
      writeFile' out $ y'

  ("*/*.md" `within` $(mkRelDir "processed/markdown")) %^> \out -> do
    logInfo $ displayShow $ "Processing " <> (toFilePath . fromWithin $ out)
    src <- blinkAndMapM $(mkRelDir "raw/mediawiki") (replaceExtension ".mediawiki") out
    a <- readFile' (fromWithin src)
    (f, _) <- splitExtension (filename $ extract src)
    l <- liftIO $ runIO $ readMediaWiki (def { readerExtensions = extensionsFromList [Ext_smart]}) a
    case l of
       Left x -> writeFile' (fromWithin out) ""
       Right x -> do
         logDebug $ displayShow x
         let x' = walk stripJunkSections . walk (convertAbilities . convertQuotes . convertNPCs) . walk (stripDataBlocks . stripLinks . deleteImages . deleteNotes) $ x
         let y = Pandoc mempty [(Header 1 nullAttr [Str (T.pack $ toFilePath $ f)])] <> x'
         k <- runPandocA $ writeMarkdown myMDWriterOptions $ y
         logDebug $ displayShow  k
         writeFile' (fromWithin out) k

  ("*" `within` $(mkRelDir "manifests/derived/")) %^> \out -> do
    let src = blinkLocalDir $(mkRelDir "manifests/original/") out
    needP [fromWithin $ src]
    (WikiManifest{..}) <- readYaml (fromWithin src)
    ys <- forP includeCategories $ recSubcats (T.pack $ toFilePath $ extract out) api
    let ys' = foldr S.union S.empty ys
    logDebug $ displayShow $ ys'
    zs <- forP (includeCategories <> toList ys') $ pagesRequest (T.pack $ toFilePath $ extract out) api
    let zs' = filter (not .  (\x -> any (`T.isInfixOf` x) ["/","&","%","+","+"])) $ join $ viewCmTitles <$> zs
    BS.writeFile (toFilePath . fromWithin $ out) $ Yaml.encode $ WikiManifest {includeCategories = [], includePages = zs', .. }

  let wikiManifest x = do
      logInfo $ displayShow $ "Opening Wiki Manifest for " <> x
      x' <- parseRelFile (T.unpack x)
      let src = $(mkRelDir "manifests/derived") </> x'
      needP [src]
      (WikiManifest{..}) <- readYaml src
      need $ flip map includePages $ T.unpack . (\a -> "processed/markdown/" <> x <> "/" <> a <> ".md")

  phony "mortalkombat" $ wikiManifest "mortalkombat.fandom.com"
  phony "pokemon"      $ wikiManifest "pokemon.gamepedia.com"
  phony "rickandmorty" $ wikiManifest "rickandmorty.fandom.com"
  phony "sonic"        $ wikiManifest "sonic.fandom.com"
  phony "startrek"     $ wikiManifest "memory-alpha.fandom.com"
  phony "wikipedia"    $ wikiManifest "en.wikipedia.org"
  phony "wow"          $ wikiManifest "wow.gamepedia.com"

  phony "train"        $ do
    needIn outputFolder [$(mkRelFile "trainingset.txt")]
    command_ [] "python3" ["gpt_2_simple.py", "finetune", "out/trainingset.txt",
                           "--sample_every", "2500",
                           "--model_dir", "out/model",
                           "--checkpoint_dir", "out/checkpoint",
                           "--print_every", "1",
                           "--save_every", "1000"]

  phony "generate"     $ do
    command_ [] "python3" ["gpt_2_simple.py", "generate",
                           "--temperature", "0.8",
                           "--checkpoint_dir", "out/checkpoint",
                           "--nsamples", "20",
                           "--folder", "out/gen",
--                           "--truncate", "<|endoftext|>",
                           "--length", "1500",
                           "--prefix","Draenei who lived during the Roman Empire",
                           "--include_prefix", "False"]

  phony "clean"        $ do
    logInfo $ "Cleaning files in " <> displayShow outputFolder
    removeFilesAfter outputFolder ["//*"]
