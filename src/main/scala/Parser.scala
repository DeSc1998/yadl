package parser

import fastparse._, NoWhitespace._

def wsSingle[$: P] = P(" " | "\t")
def ws[$: P] = P((multilineCommentP | wsSingle).rep).opaque("<whitespace>")
def newline[$: P] = P("\n\r" | "\r" | "\n").opaque("<newline>")
def wsAndNewline[$: P] =
  P((multilineCommentP | wsSingle | newline).rep)
    .opaque("<whitespace or newline>")

def arihmeticOperatorP[$: P] = P((CharIn("*/+^%") | "-").!).map {
  case "*" => ArithmaticOps.Mul
  case "+" => ArithmaticOps.Add
  case "-" => ArithmaticOps.Sub
  case "/" => ArithmaticOps.Div
  case "^" => ArithmaticOps.Expo
  case "%" => ArithmaticOps.Mod
  case _   => assert(false, "arithmatic operator not defined")
}

def booleanOperatorP[$: P] = P(("and" | "or" | "not").!).map {
  case "and" => BooleanOps.And
  case "or"  => BooleanOps.Or
  case "not" => BooleanOps.Not
  case _     => assert(false, "boolean operator not defined")
}

def compareOperatorP[$: P] = P(("==" | "!=" | "<=" | ">=" | "<" | ">").!).map {
  case "<"  => CompareOps.Less
  case "<=" => CompareOps.LessEq
  case ">"  => CompareOps.Greater
  case ">=" => CompareOps.GreaterEq
  case "==" => CompareOps.Eq
  case "!=" => CompareOps.NotEq
  case _    => assert(false, "comparision operator not defined")
}

def condition[$: P]: P[Expression] =
  P("(" ~ ws ~ expression(identifierP, 0) ~ ws ~ ")").opaque("<condition>")

def initialBranch[$: P]: P[Branch] =
  P(
    "if" ~ ws ~ condition ~ ws ~ codeBlock
  ).map(Branch(_, _))

def whileLoop[$: P]: P[Statement] =
  P("while" ~ ws ~ condition ~ ws ~ codeBlock)
    .map((c, sts) => WhileLoop(Branch(c, sts)))

def elif[$: P]: P[Branch] =
  P(
    "elif" ~ ws ~ condition ~ ws ~ codeBlock
  ).map(Branch(_, _))

def endBranch[$: P]: P[Seq[Statement]] =
  P("else" ~ ws ~ codeBlock)

def ifStatement[$: P]: P[Statement] =
  (initialBranch ~ newline.? ~ (ws ~ elif ~ newline.?).rep ~ ws ~ (newline.? ~ ws ~ endBranch).?)
    .map(If(_, _, _))

def returnP[$: P]: P[Statement] =
  P("return" ~ ws ~ expression(identifierP, 0)).map(Return(_))

def statementP[$: P]: P[Statement] =
  returnP | whileLoop | ifStatement | functionCallStatement | structuredAssignmentP | assignmentP

def codeBlock[$: P]: P[Seq[Statement]] =
  P("{" ~ newline ~ (ws ~ statementP.? ~ ws ~ newline).rep ~ ws ~ "}").map(l =>
    l.map(_.toList).flatten
  )

def functionDefBodyP[$: P]: P[Seq[Statement]] =
  codeBlock | expression(identifierP, 0).map((v) => Seq(Return(v)))

def functionDefArgsP[$: P]: P[Seq[String]] = (
  identifierP ~ (ws ~ "," ~ ws ~ functionDefArgsP).?
).map((i, is) =>
  (i, is) match {
    case (Identifier(n), Some(args)) => n +: args
    case (Identifier(n), None)       => Seq(n)
  }
)

def functionDefP[$: P]: P[Expression] = (
  "(" ~ ws ~ functionDefArgsP.? ~ ws ~ ")" ~ ws ~ "=>" ~ ws ~ functionDefBodyP
).map((bs, b) =>
  bs match {
    case Some(args) => Function(args, b)
    case None       => Function(Seq(), b)
  }
)

def noneP[$: P]: P[Expression] = P("none").!.map(_ => NoneValue())

def valueP[$: P](idParser: => P[Expression]): P[Expression] =
  noneP | booleanP | stringP | unaryOpExpression(
    idParser
  ) | dictionaryP | arrayLiteralP | structureAccess | functionCallExpression(
    idParser
  ) | numberP

def booleanP[$: P]: P[Expression] = P(
  ("true" | "false").!
).opaque("<boolean value>").map {
  case "true"  => Bool(true)
  case "false" => Bool(false)
  case _       => assert(false, "unreachable")
}

def functionCallArgsP[$: P]: P[Seq[Expression]] = (
  expression(identifierP, 0) ~ (ws ~ "," ~ ws ~ functionCallArgsP).?
).map((v, vs) =>
  vs match {
    case None     => Seq(v)
    case Some(xs) => v +: xs
  }
)

def functionName[$: P](idParser: => P[Expression]): P[Expression] =
  idParser | wrappedExpression(idParser)

def functionCallManyArgs[$: P]: P[Seq[Seq[Expression]]] =
  P(ws ~ "(" ~ ws ~ functionCallArgsP.? ~ ws ~ ")")
    .map(_.getOrElse(Seq()))
    .rep

def functionCallExpression[$: P](idParser: => P[Expression]): P[Expression] = P(
  functionName(idParser) ~ functionCallManyArgs
) // .opaque("<function call>")
  .map((n, bs) =>
    bs.length match {
      case 0 =>
        n
      case _ =>
        bs.foldLeft(n)(FunctionCall(_, _)) match {
          case fc: FunctionCall => fc
        }
    }
  )

def functionCallStatement[$: P]: P[Statement] = P(
  functionName(identifierP) ~ functionCallManyArgs
).opaque("<function call>")
  .filter((_, bs) => bs.length > 0)
  .map((n, bs) =>
    bs.foldLeft(n)(FunctionCall(_, _)) match {
      case fc: FunctionCall => fc
      case _                => assert(false, "unreachable")
    }
  )

def binaryOperator[$: P]: P[Operator] =
  arihmeticOperatorP.map(ArithmaticOp(_)) | booleanOperatorP.map(
    BooleanOp(_)
  ) | compareOperatorP.map(CompareOp(_))

def unaryOperator[$: P]: P[Operator] =
  import ArithmaticOps._, BooleanOps._, CompareOps._
  import ArithmaticOp as A, BooleanOp as B, CompareOp as C

  def eq(left: Operator, right: Operator): Boolean = (left, right) match {
    case (l: A, r: A) => l.op == r.op
    case (l: B, r: B) => l.op == r.op
    case (l: C, r: C) => l.op == r.op
    case _            => false
  }

  def isAnyOf(op: Operator, targets: Seq[Operator]): Boolean =
    targets.foldLeft(false)((acc: Boolean, x: Operator) => acc || eq(x, op))

  val unaryOps = Seq(A(Add), A(Sub), B(Not))

  binaryOperator.filter { isAnyOf(_, unaryOps) }

// Some operators should be calculated before other operators.
// eg. 4 - 4 * 4 => 4*4 gets calculated before 4-4.
// So the "precedence" of * is higher than of -. This is handled here.
def precedenceOf(oper: Operator): Int = oper match {
  case ArithmaticOp(op) =>
    op match {
      case ArithmaticOps.Add  => 5
      case ArithmaticOps.Sub  => 5
      case ArithmaticOps.Mul  => 6
      case ArithmaticOps.Div  => 6
      case ArithmaticOps.Mod  => 6
      case ArithmaticOps.Expo => 8
    }
  case BooleanOp(op) =>
    op match {
      case BooleanOps.And => 2
      case BooleanOps.Or  => 1
      case BooleanOps.Not => 3
    }
  case _ => 4
}

def unaryOpExpression[$: P](idParser: => P[Expression]): P[Expression] =
  (unaryOperator ~ ws ~ expression(idParser, 7))
    .opaque("<unary operator>")
    .map((op, value) => UnaryOp(op, value))

def binaryOpExpression[$: P](
    idParser: => P[Expression],
    prec: Int
): P[Expression] =
  def precedenceFilter(op: Operator): Boolean =
    val op_prec = precedenceOf(op)
    op_prec > prec || op_prec == prec && op == ArithmaticOp(ArithmaticOps.Expo)

  def expr(op: Operator): P[(Operator, Expression)] =
    (wsAndNewline ~ expression(idParser, precedenceOf(op))).map((e) => (op, e))

  (valueP(idParser) ~/ (wsAndNewline ~ binaryOperator
    .filter(precedenceFilter)
    .flatMap(expr)).rep).map((l, rest) =>
    rest.foldLeft(l)((acc, v: (Operator, Expression)) =>
      BinaryOp(acc, v._1, v._2)
    )
  )

def wrappedExpression[$: P](idParser: => P[Expression]): P[Expression] =
  P(
    "(" ~ wsAndNewline ~ expression(idParser, 0) ~ wsAndNewline ~ ")"
  ).map(Wrapped(_))

def expression[$: P](idParser: => P[Expression], prec: Int): P[Expression] = (
  functionDefP | binaryOpExpression(idParser, prec)
)

def identifierP[$: P]: P[Identifier] = P(!(CharIn("^")) ~ CharIn("a-zA-z0-9_"))
  .rep(min = 1)
  .!
  .filter(s => !(s(0) == '_' || s(0).isDigit))
  .map(Identifier(_))
  .opaque("<identifier>")

def assignmentP[$: P]: P[Statement] =
  (identifierP.! ~/ ws ~ "=" ~ ws ~ expression(identifierP, 0)).map((n, v) =>
    Assignment(n, v)
  )

def structuredAssignmentP[$: P]: P[Statement] =
  (structureAccess ~/ ws ~ "=" ~ ws ~ expression(identifierP, 0))
    .filter((s, _) => s.isInstanceOf[StructureAccess])
    .map((n, v) => StructuredAssignment(n.asInstanceOf[StructureAccess], v))

def inlineTextP[$: P]: P[Unit] = P(!newline ~ AnyChar).rep
def inlineCommentP[$: P]: P[Unit] = P("//" ~ inlineTextP ~ newline)

def multilineCommentP[$: P]: P[Unit] = P("/*" ~ (!("*/") ~ AnyChar).rep ~ "*/")

def commentP[$: P] = P(inlineCommentP | multilineCommentP)

// Root rule
def yadlParser[$: P]: P[Seq[Statement]] =
  ((statementP.? ~ ws ~ (commentP | newline))).rep.map(l => l.flatMap(_.toList))
  // fastparse (the parsing library that we use) syntax:
  // This code means that we call a parser for a statement, then a parser for whitespaces, then for newlines.
  // This can be repeated any number of times (signaled by .rep). As regex: (statement whitespace* newline)*

//Hilfsparser Number
def digitsP[$: P](digitParser: => P[Char]): P[String] =
  (digitParser ~ (P("_").? ~ digitParser).rep)
    .map((f, r) => r.foldLeft(StringBuffer().append(f))(_.append(_)).toString)

def dezimalP[$: P] = P(CharIn("0-9").!).map(_.head)
def binaryP[$: P] = P(CharIn("01").!).map(_.head)
def octalP[$: P] = P(CharIn("0-7").!).map(_.head)
def hexadezimalP[$: P] = P(CharIn("0-9a-fA-F").!).map(_.head)

//Hilffunktion für Number map
def basisToDecimal(
    numberString: String,
    restString: String,
    basis: Int
): Double =
  val numberLong = java.lang.Long.parseLong(numberString, basis).toDouble
  val restLong = java.lang.Long.parseLong(restString, basis).toDouble
  val fraction = restLong / scala.math.pow(basis, restString.length)
  numberLong + fraction

//Parser Number
enum Base:
  case Binary, Octal, Decimal, Hexadecimal

def basePrefix[$: P] =
  P("0b".! | "0o".! | "0x".!).?.map {
    case Some("0b") => Base.Binary
    case Some("0o") => Base.Octal
    case Some("0x") => Base.Hexadecimal
    case None       => Base.Decimal
  }

def numberDigits[$: P](baseType: Base) = baseType match {
  case Base.Decimal     => digitsP(dezimalP)
  case Base.Octal       => digitsP(octalP)
  case Base.Binary      => digitsP(binaryP)
  case Base.Hexadecimal => digitsP(hexadezimalP)
}

def dotDigits[$: P](base: Base): P[Number] =
  ("." ~ numberDigits(base)).map(s =>
    base match
      case Base.Binary      => YadlFloat(basisToDecimal("0", s, 2))
      case Base.Octal       => YadlFloat(basisToDecimal("0", s, 8))
      case Base.Decimal     => YadlFloat(("0." + s).toDouble)
      case Base.Hexadecimal => YadlFloat(basisToDecimal("0", s, 16))
  )

def digitsDotDigits[$: P](base: Base): P[Number] =
  (numberDigits(base) ~ "." ~ numberDigits(base)).map((f, r) =>
    base match
      case Base.Binary      => YadlFloat(basisToDecimal(f, r, 2))
      case Base.Octal       => YadlFloat(basisToDecimal(f, r, 8))
      case Base.Decimal     => YadlFloat((f + "." + r).toDouble)
      case Base.Hexadecimal => YadlFloat(basisToDecimal(f, r, 16))
  )

def digits[$: P](base: Base): P[Number] =
  (numberDigits(base)).map(s =>
    base match
      case Base.Binary      => YadlInt(java.lang.Long.parseLong(s, 2))
      case Base.Octal       => YadlInt(java.lang.Long.parseLong(s, 8))
      case Base.Decimal     => YadlInt(s.toInt)
      case Base.Hexadecimal => YadlInt(java.lang.Long.parseLong(s, 16))
  )

def numberFull[$: P](base: Base): P[Number] =
  dotDigits(base) | digitsDotDigits(base) | digits(base)

def numberP[$: P]: P[Number] =
  basePrefix.flatMap(numberFull).opaque("<number>")

//Hilfsparser String
def unescape(input: String): String =
  input
    .replace("\\\\", "\\")
    .replace("\\t", "\t")
    .replace("\\b", "\b")
    .replace("\\n", "\n")
    .replace("\\r", "\r")
    .replace("\\f", "\f")
    .replace("\\\"", "\"")
    .replace("\\\'", "\'")

def charForStringDoubleQuote[$: P] = P(
  !("\"" | newline) ~ ("\\\"" | "\\\\" | AnyChar)
)
def charForStringSingleQuote[$: P] = P(
  !("\'" | newline) ~ ("\\\'" | "\\\\" | AnyChar)
)
def charForMultilineStringDoubleQuote[$: P] = P(!"\"\"\"" ~ ("\\\\" | AnyChar))
def charForMultilineStringSingleQuote[$: P] = P(!"\'\'\'" ~ ("\\\\" | AnyChar))

def expressionEnd[$: P] = P(ws ~ expression(identifierP, 0) ~ ws ~ End)

def formatStringMap(input: String): FormatString = {
  // Replace all occurrences of "\\{" with newline "\n"
  val replacedInput = input.replace("\\{", "\n").replace("\\}", "\r")

  var result: List[Expression] = List()

  var next_input = ""
  var braces_open = false
  for (a <- replacedInput) {
    if (a == '{') {
      if (braces_open == false) {
        braces_open = true
        result = result :+ StdString(
          unescape(next_input.replace("\n", "{").replace("\r", "}"))
        )
        next_input = ""
      } else assert(false, "Braces opened before old one closed")
    } else if (a == '}') {
      if (braces_open == false)
        assert(false, "Braces closed without being open")
      else {
        braces_open = false
        parse(next_input, expressionEnd(_)) match {
          case Parsed.Success(ident, _) => result = result :+ ident
          case _                        => assert(false, "parsing failed")
        }
        // val Parsed.Success(ident, _) = parse(next_input, expressionEnd(_))
        // result = result :+ ident
        next_input = ""
      }
    } else {
      next_input += a
    }
  }
  if (braces_open == true) assert(false, "Braces not closed")
  if (next_input != "") {
    result = result :+ StdString(
      unescape(next_input.replace("\n", "{").replace("\r", "}"))
    )
  }

  FormatString(result)
}

//Parser String
//def formatStringP[$: P] = P()
def stdStringP[$: P] = P(
  (("\"" ~ charForStringDoubleQuote.rep.! ~ "\"") |
    ("\'" ~ charForStringSingleQuote.rep.! ~ "\'")).map(x =>
    StdString(unescape(x))
  )
)

def stdMultiStringP[$: P] = P(
  (("\"\"\"" ~ charForMultilineStringDoubleQuote.rep.! ~ "\"\"\"") |
    ("\'\'\'" ~ charForMultilineStringSingleQuote.rep.! ~ "\'\'\'")).map(x =>
    StdString(unescape(x))
  )
)

def formatStringP[$: P]: P[FormatString] = P(
  (
    ("f\"" ~ charForStringDoubleQuote.rep.! ~ "\"") |
      ("f\'" ~ charForStringSingleQuote.rep.! ~ "\'")
  ).map(formatStringMap)
)

def stringP[$: P]: P[Expression] = formatStringP | stdMultiStringP | stdStringP

def dictionaryEntries[$: P]: P[Dictionary] =
  def dictionaryEntry[$: P]: P[DictionaryEntry] =
    (valueP(identifierP) ~ ws ~ ":" ~ ws ~ valueP(identifierP))
      .opaque("<dictionary entry>")
      .map(DictionaryEntry(_, _))

  def repeatedEntries[$: P](
      entry: => P[DictionaryEntry]
  ): P[Seq[DictionaryEntry]] =
    P((ws ~ entry).rep(sep = (ws ~ "," ~ ws ~ newline.?)))

  (ws ~ repeatedEntries(dictionaryEntry) ~/ ws ~ newline.?)
    .map(Dictionary(_))

def dictionaryP[$: P]: P[Dictionary] =
  P("{" ~ ws ~ newline.? ~ dictionaryEntries ~ ws ~ "}")

def openIndex[$: P]: P[Unit] =
  P(CharPred(_ == '[')).opaque("<open index>")
def closeIndex[$: P]: P[Unit] =
  P(CharPred(_ == ']')).opaque("<close index>")

def internalIdentifier[$: P]: P[Expression] =
  P(!(closeIndex | openIndex | CharIn("^")) ~ CharIn("a-zA-z0-9_"))
    .rep(min = 1)
    .!
    .filter(s => !(s(0) == '_' || s(0).isDigit))
    .map(Identifier(_))

def structureAccess[$: P]: P[Expression] =

  def access[$: P]: P[Expression] =
    P(openIndex ~ ws ~ expression(internalIdentifier, 0) ~ ws ~ closeIndex)

  P(internalIdentifier ~ (ws ~ access).rep(min = 1))
    .map((i, v) => v.foldLeft(i)((acc, a) => StructureAccess(acc, a)))

//Parser Array (we use structureAccess for accessing arrays)
def arrayLiteralP[$: P]: P[ArrayLiteral] =
  P(
    "[" ~ ws ~ expression(internalIdentifier, 0).rep(sep =
      ws ~ "," ~ ws ~ newline.?
    ) ~ ws ~ newline.? ~ "]"
  )
    .map(ArrayLiteral.apply)
