{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}

module Search
  ( search
  , makeQuery
  , startThread
  ) where

import qualified Data.List
import qualified Data.Map.Strict as Map
import qualified Data.Char
import qualified Data.Array
import qualified Data.Tuple
import qualified Data.Maybe
import qualified Data.ByteString.Char8 as C

import Control.Monad
import Control.Concurrent
import Control.Monad.STM
import Control.Concurrent.STM.TMVar

import Text.Regex.PCRE
import Data.Bits ((.|.))

import Control.Applicative ((<|>))
import qualified Hoogle

import qualified Entry
import qualified Hoo
import Utils


-- TODO @incomplete: refine this into smaller types?
data Query
  = Global String
  | Limited String String
  | Hoogle String
  deriving (Show)


makeQuery :: String -> Maybe Query
makeQuery str =
  case str of
    [] ->
      Nothing

    ('/':'h':'h':c:t) ->
      Just $ Hoogle (c:t)

    ('/':c1:c2:c3:t) ->
      -- limit using prefix, like this: /tfsigmoid
      Just $ Limited [c1, c2] (c3:t)

    ('/':_) ->
      -- cannot start a search with /
      Nothing

    _ ->
      case reverse str of
        (c1:c2:'/':c3:t) ->
          -- limit using suffix, like this: sigmoid/tf
          Just $ Limited [c2, c1] (reverse (c3:t))
        _ ->
          Just . Global $ str


-- shortcuts :: [(AbbrStriing, Language)]
shortcuts = Map.fromList
  [ ("hs", "Haskell")
  , ("py", "Python")
  , ("tf", "TensorFlow")
  , ("np", "NumPy")
  , ("pd", "pandas")
  , ("er", "Erlang")
  ]


filterEntry :: Query -> [Entry.T] -> [Entry.T]
filterEntry (Global _) es = es
filterEntry (Limited abbr _) es =
  case Map.lookup abbr shortcuts of
    Nothing ->
      []
    Just language ->
      filter (\entry -> Entry.language entry == language) es
filterEntry (Hoogle _) _ = undefined


getQueryTextLower query =
  let queryStr = case query of
        Global s -> s
        Limited _ s -> s
        Hoogle _ -> undefined
  in map Data.Char.toLower queryStr


search :: [Entry.T] -> Int -> Query -> [Entry.T]
search allEntries limit query =
  let queryStr = getQueryTextLower query
      entries = filterEntry query allEntries
  in entries
       |> map (distance queryStr . Entry.nameLower)
       |> flip zip entries
       |> filter (Data.Maybe.isJust . fst)
       |> Data.List.sort
       |> map snd
       |> take limit


-- note: this is not a proper metric
distance :: String -> C.ByteString -> Maybe Float
distance query target =
  let a = subStringDistance (C.pack query) target
      b = regexDistance (queryToRegex query) (length query) target
  in a <|> b


-- TODO @incomplete: a match at the begining is better than a match at the end
subStringDistance :: C.ByteString -> C.ByteString -> Maybe Float
subStringDistance query target =
  if query `C.isInfixOf` target
    then
      let epsilon = 0.00001
          weight = fromIntegral (C.length target) / fromIntegral (C.length query)
      in Just $ epsilon * weight
    else
      Nothing


regexDistance :: Regex -> Int -> C.ByteString -> Maybe Float
regexDistance regex queryLength target =
  case matchAll regex target of
    [] ->
      Nothing
    matchesArray ->
      let (matchOffset, matchLength) = matchesArray
            |> map (Data.Array.! 0)
            |> Data.List.sortBy (\a b -> compare (Data.Tuple.swap a) (Data.Tuple.swap b))
            |> head

          matchString = subString target matchOffset matchLength

          weight = fromIntegral (C.length target) / fromIntegral queryLength

          d = fromIntegral (C.length matchString - queryLength) / fromIntegral queryLength

      in Just $ d * weight


queryToRegex :: String -> Regex
queryToRegex query =
  query
    |> map escape
    |> Data.List.intercalate ".*?"
    |> C.pack
    |> makeRegexOpts compOpts defaultExecOpt
  where
    -- https://www.pcre.org/original/doc/html/pcrepattern.html#SEC5
    escape c
      | Data.Char.isAlphaNum c = [c]
      | otherwise = ['\\', c]
    compOpts = foldl (.|.) defaultCompOpt [compCaseless]


subString :: C.ByteString -> Int -> Int -> C.ByteString
subString str offset length' =
  str |> C.drop offset |> C.take length'

-- TODO @incomplete: this function is too ugly
startThread :: [Entry.T] -> Maybe FilePath -> TMVar String -> ([Entry.T] -> IO ())-> IO ThreadId
startThread entries hooMay querySlot handleEntries =
  case hooMay of
    Nothing -> forkIO $ loop False undefined
    Just dbPath -> forkIO $ Hoogle.withDatabase dbPath (loop True)
  where
    loop hasDb db = forever $ do
      let limit = 27
      queryStr <- atomically $ takeTMVar querySlot
      let matches = case Search.makeQuery queryStr of
            Nothing ->
              []

            Just (Hoogle s) ->
              if hasDb
                then
                  Hoo.search db limit s
                else
                  -- TODO @incomplete: warn user about the lack of hoogle database
                  []

            Just query ->
              Search.search entries limit query

      handleEntries matches
