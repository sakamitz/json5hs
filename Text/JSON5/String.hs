{-# LANGUAGE CPP #-}
-- | Basic support for working with JSON5 values.
module Text.JSON5.String
     (
       -- * Parsing
       GetJSON
     , runGetJSON

       -- ** Reading JSON5
     , readJSNull
     , readJSBool
     , readJSString
     , readJSRational
     , readJSInfNaN
     , readJSArray
     , readJSObject

     , readJSValue
     , readJSTopType

       -- ** Writing JSON5
     , showJSNull
     , showJSBool
     , showJSArray
     , showJSObject
     , showJSRational
     , showJSInfNaN

     , showJSValue
     , showJSTopType
     ) where

import Text.JSON5.Types (JSValue(..),
                         JSNumber(..), fromJSInfNaN, fromJSRational,
                         JSString, toJSString, fromJSString,
                         JSObject, toJSObject, fromJSObject)

import Control.Monad (liftM, ap)
import Control.Applicative((<$>))
import qualified Control.Applicative as A
import Data.Char (isSpace, isDigit, isAlpha, isAlphaNum, digitToInt)
import Data.Ratio (numerator, denominator, (%))
import Numeric (readHex, readDec, showHex)

-- -----------------------------------------------------------------
-- | Parsing JSON5

-- | The type of JSON5 parsers for String
newtype GetJSON a = GetJSON { un :: String -> Either String (a,String) }

instance Functor GetJSON where
  fmap = liftM

instance A.Applicative GetJSON where
  pure  = return
  (<*>) = ap

#if __GLASGOW_HASKELL__ >= 808
instance Monad GetJSON where
  return x        = GetJSON (\s -> Right (x,s))
  GetJSON m >>= f = GetJSON (\s -> case m s of
                                     Left err -> Left err
                                     Right (a,s1) -> un (f a) s1)

instance MonadFail GetJSON where
  fail x          = GetJSON (\_ -> Left x)

#else
instance Monad GetJSON where
  return x        = GetJSON (\s -> Right (x,s))
  fail x          = GetJSON (\_ -> Left x)
  GetJSON m >>= f = GetJSON (\s -> case m s of
                                     Left err -> Left err
                                     Right (a,s1) -> un (f a) s1)
#endif

-- | Run a JSON5 reader on an input String, returning some Haskell value.
-- All input will be consumed.
runGetJSON :: GetJSON a -> String -> Either String a
runGetJSON (GetJSON m) s = case m s of
     Left err    -> Left err
     Right (a,t) -> case t of
                        [] -> Right a
                        _  -> Left $ "Invalid tokens at end of JSON5 string: "++ context t

getInput :: GetJSON String
getInput = GetJSON (\s -> Right (s,s))

setInput :: String -> GetJSON ()
setInput s = GetJSON (\_ -> Right ((),s))

-------------------------------------------------------------------------

-- | Find 8 chars context, for error messages
context :: String -> String
context s = take 8 s

-- | Read the JSON5 null type
readJSNull :: GetJSON JSValue
readJSNull = do
  xs <- getInput
  case xs of
    'n':'u':'l':'l':xs1 -> setInput xs1 >> return JSNull
    _ -> fail $ "Unable to parse JSON5 null: " ++ context xs

tryJSNull :: GetJSON JSValue -> GetJSON JSValue
tryJSNull k = do
  xs <- getInput
  case xs of
    'n':'u':'l':'l':xs1 -> setInput xs1 >> return JSNull
    _ -> k

-- | Read the JSON5 Bool type
readJSBool :: GetJSON JSValue
readJSBool = do
  xs <- getInput
  case xs of
    't':'r':'u':'e':xs1 -> setInput xs1 >> return (JSBool True)
    'f':'a':'l':'s':'e':xs1 -> setInput xs1 >> return (JSBool False)
    _ -> fail $ "Unable to parse JSON5 Bool: " ++ context xs


-- | Strings

-- Strings may be single quoted.
-- Strings may span multiple lines by escaping new line characters.
-- Strings may include character escapes.

-- | Read the JSON5 String type
readJSString :: Char -> GetJSON JSValue
readJSString sep = do
  x <- getInput
  case x of
       sep : cs -> parse [] cs
       _        -> fail $ "Malformed JSON5: expecting string: " ++ context x
 where
  parse rs cs =
    case cs of
      '\\': c : ds -> esc rs c ds
      c   : ds
       | c == sep -> do setInput ds
                        return (JSString (toJSString (reverse rs)))
       | c >= '\x20' && c <= '\xff' -> parse (c:rs) ds
       | c < '\x20'     -> fail $ "Illegal unescaped character in string: " ++ context cs
       | i <= 0x10ffff  -> parse (c:rs) ds
       | otherwise -> fail $ "Illegal unescaped character in string: " ++ context cs
       where
        i = (fromIntegral (fromEnum c) :: Integer)
      _ -> fail $ "Unable to parse JSON5 String: unterminated String: " ++ context cs

  esc rs c cs = case c of
   '\n' -> parse rs cs
   '\\' -> parse ('\\' : rs) cs
   '"'  -> parse ('"'  : rs) cs
   '\'' -> parse ('\'' : rs) cs
   'n'  -> parse ('\n' : rs) cs
   'r'  -> parse ('\r' : rs) cs
   't'  -> parse ('\t' : rs) cs
   'f'  -> parse ('\f' : rs) cs
   'b'  -> parse ('\b' : rs) cs
   '/'  -> parse ('/'  : rs) cs
   'u'  -> case cs of
             d1 : d2 : d3 : d4 : cs' ->
               case readHex [d1,d2,d3,d4] of
                 [(n,"")] -> parse (toEnum n : rs) cs'
                 x -> fail $ "Unable to parse JSON5 String: invalid hex: " ++ context (show x)
             _ -> fail $ "Unable to parse JSON5 String: invalid hex: " ++ context cs

   _ -> fail $ "Unable to parse JSON5 String: invalid escape char: " ++ show c


-- | Numbers

-- Numbers may be hexadecimal.
-- Numbers may have a leading or trailing decimal point.
-- Numbers may be IEEE 754 positive infinity, negative infinity, and NaN.
-- Numbers may begin with an explicit plus sign.

-- | Read an Integer or Double in JSON5 format, returning a Rational
readJSRational :: GetJSON Rational
readJSRational = do
  cs <- getInput
  case cs of
    '-' : ds -> negate <$> pos ds
    '+' : ds -> pos ds
    '.' : _  -> frac 0 cs
    _        -> pos cs

  where
   pos [] = fail $ "Unable to parse JSON5 Rational: " ++ context []
   pos cs =
     case cs of
       '.':ds -> frac 0 cs
       '0':'x':ds -> hex ds
       c  : ds
        | isDigit c -> readDigits (digitToIntI c) ds
        | otherwise -> fail $ "Unable to parse JSON5 Rational: " ++ context cs

   readDigits acc [] = frac (fromInteger acc) []
   readDigits acc (x:xs)
    | isDigit x = let acc' = 10*acc + digitToIntI x in
                      acc' `seq` readDigits acc' xs
    | otherwise = frac (fromInteger acc) (x:xs)

   hex cs = case readHex cs of
      [(a,ds)] -> do setInput ds
                     return (fromIntegral a)
      _        -> fail $ "Unable to parse JSON5 hexadecimal: " ++ context cs

   frac n ('.' : ds) =
       case span isDigit ds of
         ([],_)  -> setInput ds >> return n
         (as,bs) -> let x = read as :: Integer
                        y = 10 ^ (fromIntegral (length as) :: Integer)
                    in exponent' (n + (x % y)) bs
   frac n cs = exponent' n cs

   exponent' n (c:cs)
    | c == 'e' || c == 'E' = (n*) <$> exp_num cs
   exponent' n cs = setInput cs >> return n

   exp_num :: String -> GetJSON Rational
   exp_num ('+':cs)  = exp_digs cs
   exp_num ('-':cs)  = recip <$> exp_digs cs
   exp_num cs        = exp_digs cs

   exp_digs :: String -> GetJSON Rational
   exp_digs cs = case readDec cs of
      [(a,ds)] -> do setInput ds
                     return (fromIntegral ((10::Integer) ^ (a::Integer)))
      _        -> fail $ "Unable to parse JSON5 exponential: " ++ context cs

   digitToIntI :: Char -> Integer
   digitToIntI = fromIntegral . digitToInt

-- | Read an Infinity or NaN in JSON5 format, returning a Float
readJSInfNaN :: GetJSON Float
readJSInfNaN = do
  cs <- getInput
  case cs of
    '-' : ds -> negate <$> pos ds
    '+' : ds -> pos ds
    _        -> pos cs

  where
   pos [] = fail $ "Unable to parse JSON5 InfNaN: " ++ context []
   pos cs =
     case cs of
       'I':'n':'f':'i':'n':'i':'t':'y':ds -> setInput ds >> return (1 / 0)
       'N':'a':'N':ds -> setInput ds >> return (acos 2)
       _ -> fail $ "Unable to parse JSON5 InfNaN: " ++ context cs

-- | Objects & Arrays

-- Object keys may be an ECMAScript 5.1 IdentifierName.
-- Objects may have a single trailing comma.
-- Arrays may have a single trailing comma.

-- | Read a list in JSON5 format
readJSArray  :: GetJSON JSValue
readJSArray  = readSequence '[' ']' ',' >>= return . JSArray

-- | Read an object in JSON5 format
readJSObject :: GetJSON JSValue
readJSObject = readAssocs '{' '}' ',' >>= return . JSObject . toJSObject


-- | Read a sequence of items
readSequence :: Char -> Char -> Char -> GetJSON [JSValue]
readSequence start end sep = do
  zs <- getInput
  case dropWhile isSpace zs of
    c : cs | c == start ->
        case dropWhile isSpace cs of
            d : ds | d == end -> setInput (dropWhile isSpace ds) >> return []
            ds                -> setInput ds >> parse []
    _ -> fail $ "Unable to parse JSON5 sequence: sequence stars with invalid character: " ++ context zs

  where
    parse rs = rs `seq` do
        a  <- readJSValue
        ds <- getInput
        case dropWhile isSpace ds of
          e : es
            | e == sep -> case dropWhile isSpace es of
                            ']':cs -> setInput cs >> return (reverse (a:rs))
                            cs     -> setInput cs >> parse (a:rs)
            | e == end -> do setInput (dropWhile isSpace es)
                             return (reverse (a:rs))
          _ -> fail $ "Unable to parse JSON5 array: unterminated array: " ++ context ds


-- | Read a sequence of JSON5 labelled fields
readAssocs :: Char -> Char -> Char -> GetJSON [(String,JSValue)]
readAssocs start end sep = do
  zs <- getInput
  case dropWhile isSpace zs of
    c:cs | c == start -> case dropWhile isSpace cs of
            d:ds | d == end -> setInput (dropWhile isSpace ds) >> return []
            ds              -> setInput ds >> parsePairs []
    _ -> fail "Unable to parse JSON5 object: unterminated object"

  where parsePairs rs = rs `seq` do
          a  <- do k  <- do x <- readJSKey
                            case x of
                              JSString s -> return (fromJSString s)
                              _          -> fail ""
                   ds <- getInput
                   case dropWhile isSpace ds of
                       ':':es -> do setInput (dropWhile isSpace es)
                                    v <- readJSValue
                                    return (k,v)
                       _      -> fail $ "Malformed JSON5 labelled field: " ++ context ds

          ds <- getInput
          case dropWhile isSpace ds of
            e : es
              | e == sep -> case dropWhile isSpace es of
                              '}':cs -> setInput cs >> return (reverse (a:rs))
                              cs     -> setInput cs >> parsePairs (a:rs)
              | e == end -> do setInput (dropWhile isSpace es)
                               return (reverse (a:rs))
            _ -> fail $ "Unable to parse JSON5 object: unterminated sequence: "
                            ++ context ds

readJSKey :: GetJSON JSValue
readJSKey = do
  zs <- getInput
  case zs of
    '"'  : _ -> readJSString '"'
    '\'' : _ -> readJSString '\''
    _        -> readSymbol zs
  where
    readSymbol [] = fail $ "Malformed JSON5 object key-value pairs: " ++ context []
    readSymbol xs@(c:cs)
      | isStart c = case span isSymbol xs of
              ([],_) -> fail $ "Malformed JSON5 object key-value pairs: " ++ context cs
              (k,ds) -> do setInput ds
                           return (JSString (toJSString k))

      | otherwise = fail $ "Malformed JSON5 object key: started with illegal character: " ++ context xs

    isStart  c = isAlpha c    || c `elem` "_$"
    isSymbol c = isAlphaNum c || c `elem` "-_"

-- | Read one of several possible JS types
readJSValue :: GetJSON JSValue
readJSValue = do
  cs <- getInput
  case cs of
    '"' : _ -> readJSString '"'
    '\'': _ -> readJSString '\''
    '[' : _ -> readJSArray
    '{' : _ -> readJSObject
    't' : _ -> readJSBool
    'f' : _ -> readJSBool
    (x:xs)
      | isSpace x -> setInput xs >> readJSValue
      | isDigit x || x == '.' -> fromJSRational <$> readJSRational
      | x `elem` "NI" -> fromJSInfNaN <$> readJSInfNaN
      | x `elem` "+-" -> case xs of
                            'I' : _ -> fromJSInfNaN <$> readJSInfNaN
                            _       -> fromJSRational <$> readJSRational
    _ -> tryJSNull
             (fail $ "Malformed JSON5: invalid token in this context " ++ context cs)

-- | Top level JSON5 can only be Arrays or Objects
readJSTopType :: GetJSON JSValue
readJSTopType = do
  cs <- getInput
  case cs of
    '[' : _ -> readJSArray
    '{' : _ -> readJSObject
    _       -> fail "Invalid JSON5: expecting a serialized object or array at the top level."

-- -----------------------------------------------------------------
-- | Writing JSON5

-- | Show strict JSON5 top level types. Values not permitted
-- at the top level are wrapped in a singleton array.
showJSTopType :: JSValue -> ShowS
showJSTopType (JSArray a)    = showJSArray a
showJSTopType (JSObject o)   = showJSObject o
showJSTopType x              = showJSTopType $ JSArray [x]

-- | Show JSON5 values
showJSValue :: JSValue -> ShowS
showJSValue v =
  case v of
    JSNull{}         -> showJSNull
    JSBool b         -> showJSBool b
    JSNumber jsn     -> showJSNumber jsn
    JSArray a        -> showJSArray a
    JSString s       -> showJSString s
    JSObject o       -> showJSObject o

-- | Write the JSON5 null type
showJSNull :: ShowS
showJSNull = showString "null"

-- | Write the JSON5 Bool type
showJSBool :: Bool -> ShowS
showJSBool True  = showString "true"
showJSBool False = showString "false"

-- | Write the JSON5 String type
showJSString :: JSString -> ShowS
showJSString x xs = quote (encJSString x (quote xs))
  where
      quote = showChar '"'

showJSNumber :: JSNumber -> ShowS
showJSNumber (JSRational r) = showJSRational r
showJSNumber (JSInfNaN n)   = showJSInfNaN n

-- | Show a Rational in JSON5 format
showJSRational :: Rational -> ShowS
showJSRational r
 | denominator r == 1   = shows $ numerator r
 | otherwise            = shows $ realToFrac r

-- | Show a Infinity or NaN in JSON5 format
showJSInfNaN :: Float -> ShowS
showJSInfNaN n
  | isNaN n     = showString "NaN"
  | n > 0       = showString "Infinity"
  | n < 0       = showString "-Infinity"


-- | Show a list in JSON format
showJSArray :: [JSValue] -> ShowS
showJSArray = showSequence '[' ']' ','

-- | Show an association list in JSON format
showJSObject :: JSObject JSValue -> ShowS
showJSObject = showAssocs '{' '}' ',' . fromJSObject

-- | Show a generic sequence of pairs in JSON format
showAssocs :: Char -> Char -> Char -> [(String,JSValue)] -> ShowS
showAssocs start end sep xs rest = start : go xs
  where
    go [(k,v)]     = '"' : encJSString (toJSString k)
                              ('"' : ':' : showJSValue v (go []))
    go ((k,v):kvs) = '"' : encJSString (toJSString k)
                              ('"' : ':' : showJSValue v (sep : go kvs))
    go []          = end : rest

-- | Show a generic sequence in JSON format
showSequence :: Char -> Char -> Char -> [JSValue] -> ShowS
showSequence start end sep xs rest = start : go xs
  where
    go [y]        = showJSValue y (go [])
    go (y:ys)     = showJSValue y (sep : go ys)
    go []         = end : rest

encJSString :: JSString -> ShowS
encJSString jss ss = go (fromJSString jss)
  where
    go s1 =
      case s1 of
        (x   :xs) | x < '\x20' -> '\\' : encControl x (go xs)
        ('"' :xs)              -> '\\' : '"'  : go xs
        ('\\':xs)              -> '\\' : '\\' : go xs
        (x   :xs)              -> x    : go xs
        ""                     -> ss

    encControl x xs = case x of
      '\b' -> 'b' : xs
      '\f' -> 'f' : xs
      '\n' -> 'n' : xs
      '\r' -> 'r' : xs
      '\t' -> 't' : xs
      _ | x < '\x10'   -> 'u' : '0' : '0' : '0' : hexxs
        | x < '\x100'  -> 'u' : '0' : '0' : hexxs
        | x < '\x1000' -> 'u' : '0' : hexxs
        | otherwise    -> 'u' : hexxs
        where hexxs = showHex (fromEnum x) xs
