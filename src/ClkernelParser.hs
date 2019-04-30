-- Parse the source code of opencl kernel file, and get kernel function declarations.
-- Copyright (c) 2019 Parker Liu<liuchangsheng30@gmail.com>
-- Created time is 2019-4-24
-- Referenced from http://stackoverflow.com/questions/6289950/
--

module Main where

import System.IO
import System.IO.Unsafe
import System.Environment
import System.FilePath

import Data.List

import Control.Monad
import Control.Arrow

import Language.C
import Language.C.Analysis
import Language.C.Analysis.SemRep
import Language.C.System.GCC

data OclCallParamType = OclParamVoid
                      | OclParamInt8
                      | OclParamUint8
                      | OclParamInt16
                      | OclParamUint16
                      | OclParamInt32
                      | OclParamUint32
                      | OclParamInt64
                      | OclParamUint64
                      | OclParamFloat
                      | OclParamDouble
                      | OclParamPointer OclCallParamType
                      deriving Eq

instance Show OclCallParamType where
  show OclParamVoid    = "void"
  show OclParamInt8    = "int8_t"
  show OclParamUint8   = "uint8_t"
  show OclParamInt16   = "int16_t"
  show OclParamUint16  = "uint16_t"
  show OclParamInt32   = "intt32_t"
  show OclParamUint32  = "uint32_t"
  show OclParamInt64   = "int64_t"
  show OclParamUint64  = "uint64_t"
  show OclParamFloat   = "float"
  show OclParamDouble  = "double"
  show (OclParamPointer t) = "cl_mem"


data OclCallParam = OclCallParam { typ  :: OclCallParamType 
                                 , name :: String
                                 }
instance Show OclCallParam where
  show (OclCallParam typ name) = show typ ++ " " ++ name

data OclCallDef = OclCallDef String OclCallParamType [OclCallParam]
                  deriving Show
type State = [OclCallDef]

asS :: (Pretty a) => a -> String
asS = show . pretty

oclParamIntType :: IntType -> OclCallParamType
oclParamIntType TyBool = OclParamInt32
oclParamIntType TyChar = OclParamInt8
oclParamIntType TySChar = OclParamInt8
oclParamIntType TyUChar = OclParamUint8
oclParamIntType TyShort = OclParamInt16
oclParamIntType TyUShort = OclParamUint16
oclParamIntType TyInt = OclParamInt32
oclParamIntType TyUInt = OclParamUint32
oclParamIntType TyLong = OclParamInt32
oclParamIntType TyULong = OclParamUint32
oclParamIntType TyLLong = OclParamInt64
oclParamIntType TyULLong = OclParamUint64

oclParamType :: Type -> Either String OclCallParamType
oclParamType (DirectType TyVoid _ _) = Right $ OclParamVoid
oclParamType (DirectType (TyIntegral intType) _ _)  = Right $ (oclParamIntType intType)
oclParamType (DirectType (TyFloating TyFloat) _ _)  = Right $ OclParamFloat
oclParamType (DirectType (TyFloating TyDouble) _ _) = Right $ OclParamDouble
oclParamType (DirectType (TyEnum e) _ _)            = Right $ OclParamInt32
oclParamType (TypeDefType (TypeDefRef i t _) _ _)   = oclParamType t
oclParamType (PtrType t _ _) = let innerType = oclParamType t
                             in case innerType of
                                  (Left _)    -> Right $ OclParamPointer OclParamVoid
                                  (Right (OclParamPointer typ)) ->
                                                 Left "Pointer to pointer declaration detected"
                                  (Right typ) -> Right $ OclParamPointer typ
oclParamType t = Left ("Unknown type " ++ (asS t))

eitherToMaybe :: Either String a -> Maybe a
eitherToMaybe (Left s) = const Nothing (error s)
eitherToMaybe (Right a) = Just a

getOclCallParam :: ParamDecl -> Maybe OclCallParam
getOclCallParam (ParamDecl vd _) =
  let (VarDecl (VarName ident _) declAttr t) = getVarDecl vd
  in fmap (\p -> OclCallParam p (identToString ident)) (eitherToMaybe $ oclParamType t)
getOclCallParam _ = Nothing

makeOclCallFun :: String -> Type -> [ParamDecl] -> Bool -> Attributes -> Maybe OclCallDef
makeOclCallFun name returnType params isVaradic attrs =
  case rtype of
    Left s  -> Nothing
    Right t -> toOclCallDef name t <$> traverse getOclCallParam params
  where toOclCallDef name t ps = OclCallDef name t ps
        rtype = oclParamType returnType

handler :: DeclEvent -> Trav State ()
handler (DeclEvent (FunctionDef fd)) =
        do error "FunctionDef not implemented"
           return ()
handler (DeclEvent (Declaration d)) =
        do
        let (VarDecl varName declAttr t) = getVarDecl d
        case t of
          (FunctionType (FunType returnType params isVaradic) attrs) ->
             do let fun = (makeOclCallFun (asS varName) returnType params isVaradic attrs)
                  in case fun of
                       Nothing -> do return ()
                       Just x  -> do modifyUserState (\s -> x : s)
                                     return ()
          _ -> do return ()
        return ()
handler _ =
        do return ()

newState :: State
newState = []

header :: String -> String
header name =
        "// This file is generated by " ++ name ++ ".cl, don't edit it!\n" ++
        "#include <stdint.h>\n\n"

footer :: [String] -> String
footer funNames = ""

outputFunDef :: OclCallDef -> String
outputFunDef (OclCallDef name returnType params) =
  "int ocl" ++ name ++ "(\n\t" ++ 
  "cl_command_queue command_queu,\n\tconst size_t* globalSize,\n\tconst size_t* localSize,\n\t" ++
  (intercalate ",\n\t" (map show params)) ++ ")\n" ++
  "{\n\tcl_int status = 0;\n\n" ++
  concat (map (\(n, p) -> printSetKernelArg n name p) $ zip [0..] params) ++
  "\tchk(status, \"" ++ name ++ "\");\n" ++
  "\n#ifdef DEBUG_KERNEL\n\tcl_event debug_event;\n" ++
  "\tstatus = clEnqueueNDRangeKernel(command_queue, " ++ name ++
  ",\n\t\t2, NULL, globalSize, localSize, 0, NULL, &debug_event);\n" ++
  "\tchk(status, \"" ++ name ++ " clEnqueueNDRangeKernel" ++ "\");\n" ++
  "\tCheckKernelEvent(debug_event, \"" ++ name ++ "\");\n" ++
  "\tclReleaseEvent(debug_event);\n" ++
  "#else\n" ++
  "\tstatus = clEnqueueNDRangeKernel(command_queue, " ++ name ++
  ",\n\t\t2, NULL, globalSize, localSize, 0, NULL, NULL);\n" ++
  "\tchk(status, \"" ++ name ++ " clEnqueueNDRangeKernel" ++ "\");\n" ++
  "#endif\n" ++
  "\treturn (int)status;\n}\n\n"

printSetKernelArg :: Int -> String -> OclCallParam -> String
printSetKernelArg n kname (OclCallParam typ name) = 
  "\tstatus |= clSetKernelArg(" ++ kname ++ ", " ++ show n ++ ", " ++
  printTypeSize typ ++ ", &" ++ name ++ ");\n"

printTypeSize :: OclCallParamType -> String
printTypeSize (OclParamPointer _) = "sizeof(cl_mem)"
printTypeSize pt = "sizeof(" ++ show pt ++ ")"

errToString :: CError -> String
errToString (CError err) = show err

main :: IO ()
main = do
    let usage = error "give file to parse"
    (opts,c_file) <- liftM (init &&& last) getArgs

    let compiler = newGCC "gcc"
    ast <- parseCFile compiler Nothing opts c_file >>= checkResult "[parsing]"

    case (runTrav newState (withExtDeclHandler (analyseAST ast) handler)) of
         Left errs -> do putStrLn ("errors: " ++ concat (map errToString errs))
         Right (decls, state) -> do putStr $ header (takeWhile (/='.') $ takeBaseName c_file)
                                    mapM_ (putStr . outputFunDef) (userState state)
                                    putStr $ footer (map funName (userState state))

    where
    checkResult :: (Show a) => String -> (Either a b) -> IO b
    checkResult label = either (error . (label++) . show) return

    funName :: OclCallDef -> String
    funName (OclCallDef name _ _) = name