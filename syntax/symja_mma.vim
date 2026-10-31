if exists("b:current_syntax")
  finish
endif

syntax sync fromstart

" Mathematica/Wolfram-style comments may nest.
syntax region symjaMmaComment start=/(\*/ end=/\*)/ contains=symjaMmaComment,symjaMmaTodo
syntax keyword symjaMmaTodo TODO FIXME NOTE XXX contained
syntax region symjaMmaString start=/"/ skip=/\\./ end=/"/ contains=symjaMmaEscape
syntax match symjaMmaEscape /\\./ contained

syntax keyword symjaMmaKeyword If Then Else Which Switch For While Do Break Continue Return
syntax keyword symjaMmaKeyword Module Block With Function Pattern Condition Set SetDelayed And Or Not
syntax keyword symjaMmaBuiltin Integrate D DSolve NDSolve Solve Reduce FindRoot N NSolve Limit Series Residue
syntax keyword symjaMmaBuiltin Factor Expand FullSimplify Simplify Together Apart Cancel Collect Coefficient
syntax keyword symjaMmaBuiltin PolynomialGCD GroebnerBasis Sin Cos Tan Cot Sec Csc ArcSin ArcCos ArcTan
syntax keyword symjaMmaBuiltin Sinh Cosh Tanh Exp Log Sqrt Abs Sign Re Im Conjugate Floor Ceiling Round
syntax keyword symjaMmaBuiltin RandomInteger RandomReal Plot Plot3D ParametricPlot ContourPlot VectorPlot
syntax keyword symjaMmaBuiltin Table Sum Product Range Map MapThread Apply Fold Nest FixedPoint Select
syntax keyword symjaMmaBuiltin List Length First Last Rest Take Drop Join Flatten Sort Union Intersection
syntax keyword symjaMmaBuiltin Print Replace ReplaceAll ReplaceRepeated DeleteCases Cases Position Part
syntax keyword symjaMmaBuiltin Derivative NumericQ IntegerQ NumberQ EvenQ OddQ MatrixForm Transpose Inverse
syntax keyword symjaMmaBuiltin Det Determinant Trace Eigenvalues Eigenvectors IdentityMatrix ZeroMatrix
syntax keyword symjaMmaBuiltin ToString ToExpression Import Export
syntax keyword symjaMmaConstant True False Null Pi E I Infinity Indeterminate ComplexInfinity

syntax match symjaMmaNumber /\<\d\+\%([.]\d\+\)\?\%([eE][+-]\?\d\+\)\?/
syntax match symjaMmaNumber /\<\d\+\%([.]\d*\)\?`\d*\%([.]\d*\)\?/
syntax match symjaMmaNumber /\<\d\+\%([.]\d*\)\?\*\^[+-]\?\d\+/
syntax match symjaMmaPattern /\<[A-Za-z$][A-Za-z0-9$]*_\{1,3}[A-Za-z$][A-Za-z0-9$]*\>/
syntax match symjaMmaPattern /___\|__\|_[A-Za-z$][A-Za-z0-9$]*\|_/
syntax match symjaMmaSlot /##\d*\|#\d*/
syntax match symjaMmaNamedCharacter /\\\[[A-Za-z$][A-Za-z0-9$]*\]/
syntax match symjaMmaContext /[A-Za-z$][A-Za-z0-9$]*`\([A-Za-z$][A-Za-z0-9$]*`\)*/

" Generic operator characters are defined first; multi-character operators
" below get priority to cover their complete token.
syntax match symjaMmaOperator /[=+*\/%<>!@&^~?-]/
syntax match symjaMmaOperator /\[\[\|\]\]/
syntax match symjaMmaOperator /===\|=!=\|:=\|:>\|->\|==\|!=\|<=\|>=/
syntax match symjaMmaOperator /&&\|||\|\/\/\.\|\/\.\|\/\/\|\/;\|@@@\|@@\|<|\||>/
syntax match symjaMmaOperator /++\|--\|+=\|-=\|\*=\|\/=\|;;\|\.\.\.\|\.\./
syntax match symjaMmaOperator /??\|?/
syntax match symjaMmaFunction /\<[A-Za-z$][A-Za-z0-9$]*\ze\s*\[/

highlight default link symjaMmaComment Comment
highlight default link symjaMmaTodo Todo
highlight default link symjaMmaString String
highlight default link symjaMmaEscape SpecialChar
highlight default link symjaMmaKeyword Keyword
highlight default link symjaMmaBuiltin Function
highlight default link symjaMmaConstant Constant
highlight default link symjaMmaNumber Number
highlight default link symjaMmaPattern Type
highlight default link symjaMmaSlot Special
highlight default link symjaMmaNamedCharacter SpecialChar
highlight default link symjaMmaContext Include
highlight default link symjaMmaOperator Operator
highlight default link symjaMmaFunction Function

let b:current_syntax = "symja_mma"
