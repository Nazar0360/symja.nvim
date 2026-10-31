if exists("b:current_syntax")
  finish
endif

syntax sync fromstart

" Symja native/relaxed syntax. Self-containing comments support nesting.
syntax region symjaComment start=/(\*/ end=/\*)/ contains=symjaComment,symjaTodo
syntax keyword symjaTodo TODO FIXME NOTE XXX contained
syntax region symjaString start=/"/ skip=/\\./ end=/"/ contains=symjaEscape
syntax match symjaEscape /\\./ contained

" Most multi-character native built-ins are case-insensitive. Keep the
" one-letter symbols D, E, I and N case-sensitive, as Symja does.
syntax case ignore
syntax keyword symjaKeyword If Then Else Which Switch For While Do Break Continue Return
syntax keyword symjaKeyword Module Block With Function Pattern Condition Set SetDelayed
syntax keyword symjaKeyword And Or Not
syntax keyword symjaBuiltin Integrate DSolve NDSolve Solve Reduce FindRoot NSolve Limit Series Residue
syntax keyword symjaBuiltin Factor Expand FullSimplify Simplify Together Apart Cancel Collect Coefficient
syntax keyword symjaBuiltin PolynomialGCD GroebnerBasis Sin Cos Tan Cot Sec Csc ArcSin ArcCos ArcTan
syntax keyword symjaBuiltin Sinh Cosh Tanh Exp Log Sqrt Abs Sign Re Im Conjugate Floor Ceiling Round
syntax keyword symjaBuiltin RandomInteger RandomReal Plot Plot3D ParametricPlot ContourPlot VectorPlot
syntax keyword symjaBuiltin Table Sum Product Range Map MapThread Apply Fold Nest FixedPoint Select
syntax keyword symjaBuiltin List Length First Last Rest Take Drop Join Flatten Sort Union Intersection
syntax keyword symjaBuiltin Print Replace ReplaceAll ReplaceRepeated DeleteCases Cases Position Part
syntax keyword symjaBuiltin Derivative NumericQ IntegerQ NumberQ EvenQ OddQ MatrixForm Transpose Inverse
syntax keyword symjaBuiltin Det Determinant Trace Eigenvalues Eigenvectors IdentityMatrix ZeroMatrix
syntax keyword symjaBuiltin ToString ToExpression Import Export
syntax keyword symjaConstant True False Null Pi Infinity Indeterminate ComplexInfinity
syntax case match
syntax keyword symjaBuiltin D N
syntax keyword symjaConstant E I

syntax match symjaNumber /\<\d\+\%([.]\d\+\)\?\%([eE][+-]\?\d\+\)\?/
syntax match symjaPattern /___\|__\|_[A-Za-z$][A-Za-z0-9$]*/
syntax match symjaSlot /#\{1,2}\d*/

" Generic operator characters go first; longer operators below take priority
" so the whole token (e.g. //., /., ->, or [[) is highlighted together.
syntax match symjaOperator /[=+*\/%<>!@&^~?-]/
syntax match symjaOperator /\[\[\|\]\]/
syntax match symjaOperator /===\|=!=\|:=\|:>\|->\|==\|!=\|<=\|>=/
syntax match symjaOperator /&&\|||\|\/\.\|\/\/\.\|\/\/\|\/;\|@@@\|@@\|<|\||>/
syntax match symjaOperator /++\|--\|+=\|-=\|\*=\|\/=/
syntax match symjaFunction /\<[A-Za-z$][A-Za-z0-9$]*\ze\s*(/

highlight default link symjaComment Comment
highlight default link symjaTodo Todo
highlight default link symjaString String
highlight default link symjaEscape SpecialChar
highlight default link symjaKeyword Keyword
highlight default link symjaBuiltin Function
highlight default link symjaConstant Constant
highlight default link symjaNumber Number
highlight default link symjaPattern Type
highlight default link symjaSlot Special
highlight default link symjaOperator Operator
highlight default link symjaFunction Function

let b:current_syntax = "symja"
