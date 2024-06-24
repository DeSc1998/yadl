import scala.util.control.Breaks._

import parser._ // To lazy to import all types individually

import ArithmaticOps.{Add, Div, Expo, Mul, Sub, Mod}
import BooleanOps.{And, Or, Not}
import CompareOps.{Eq, Greater, GreaterEq, Less, LessEq, NotEq}

val builtins = stdlib.stdlib

type HashMap[K, V] = scala.collection.mutable.HashMap[K, V]

class Scope(
    parent: Scope = null,
    funArgs: Seq[String] = Seq(),
    callArgs: Seq[Value] = Seq()
):
  private var parentScope: Scope = parent
  private var _result: Value = null
  private var _capture: Capture = null
  private var localVars: HashMap[String, Value] =
    new HashMap().addAll(funArgs.zip(callArgs))
  private var localFuncs: HashMap[String, parser.Function] = new HashMap

  def result: Option[Value] =
    if (this._result == null) None
    else
      val tmp = this._result
      this._result = null
      Some(tmp)

  def hasResult: Boolean = this._result != null
  def isGlobal: Boolean = this.parentScope == null

  def returnValue(value: Value): Scope =
    this._result = value
    this

  def withCapture(c: Capture): Scope =
    var tmp = this.clone()
    tmp._capture = c
    tmp

  private def lookupCapture(identifier: Identifier): Option[Value] =
    if (this._capture != null) this._capture.lookup(identifier)
    else None

  def lookup(identifier: Identifier): Option[Value] =
    this.lookupCapture(identifier) match {
      case Some(value) =>
        return Some(value)
      case None => {}
    }

    this.localVars.get(identifier.name) match {
      case Some(Identifier(name)) =>
        if (name == identifier.name) // 'x' -> 'x'
          lookupInParent(identifier)
        else
          this.lookup(Identifier(name))
      case Some(value) => Some(value)
      case None =>
        lookupInParent(identifier) match
          case Some(value) => Some(value)
          case None        => this.lookupFunction(identifier)

    }

  def lookupFunction(identifier: Identifier): Option[parser.Function] =
    this.localFuncs.get(identifier.name) match {
      case value: Some[parser.Function] => value
      case None                         => lookupFunctionInParent(identifier)
    }

  private def lookupInParent(identifier: Identifier): Option[Value] =
    if (this.parentScope != null)
      this.parentScope.lookup(identifier)
    else
      None

  private def lookupFunctionInParent(
      identifier: Identifier
  ): Option[parser.Function] =
    if (this.parentScope != null)
      this.parentScope.lookupFunction(identifier)
    else
      None

  override def clone(): Scope =
    var tmp = new Scope
    tmp.localFuncs = this.localFuncs.clone()
    tmp.localVars = this.localVars.clone()
    if (this.parentScope != null)
      tmp.parentScope = this.parentScope.clone()
    tmp

  def update(identifier: Identifier, value: Value): Scope =
    value match {
      case f: Function =>
        this.lookupFunction(identifier) match {
          case None =>
            this.localFuncs.update(identifier.name, f)
          case Some(func: Function) =>
            f.capture = Some(Capture(this, f.args, f.body))
            this.localFuncs.update(identifier.name, f)
        }
      case v: Value =>
        this.localVars.update(identifier.name, v)
    }
    this
end Scope

class Capture(
    scope: Scope,
    functionArguments: Seq[String],
    functionBoby: Seq[Statement]
):
  private var captures: HashMap[String, Value] = {
    val externals = allExternalIdentifiers(functionArguments, functionBoby)
    val pairs = externals.map(e =>
      scope.lookup(Identifier(e)) match {
        case Some(value) =>
          val Some(v) = evalValue(value, scope).result: @unchecked
          (e, v)
        case None =>
          if (e == "print" || builtins.contains(e))
            ("_", Function(Seq(), Seq(Expression(Bool(false))), null))
          else
            assert(false, s"'$e' can not be captured because it does not exist")
      }
    )
    var tmp = new HashMap[String, Value]
    tmp.addAll(pairs)
  }

  private def allExternalIdentifiers(
      funcArgs: Seq[String],
      functionBoby: Seq[Statement]
  ): Seq[String] = {
    def externalsValue(
        accs: Seq[String],
        locals: Seq[String],
        value: Value
    ): (Seq[String], Seq[String]) =
      val cs = externalsOfValue(accs ++ locals, value)
        .flatMap(e => if (locals.contains(e)) Seq() else Seq(e))
      (cs, locals)

    def externalsStatements(
        accs: Seq[String],
        locals: Seq[String],
        sts: Seq[Statement]
    ): (Seq[String], Seq[String]) =
      val cs = allExternalIdentifiers(accs ++ locals, sts)
        .flatMap(e => if (locals.contains(e)) Seq() else Seq(e))
      (cs, locals)

    val (ext, _) =
      functionBoby.foldLeft((Seq(): Seq[String], funcArgs))((acc, elem) =>

        var (accs, locals) = acc
        elem match {
          case Assignment(varName, value) =>
            if (!accs.contains(varName) && !locals.contains(varName)) {
              // NOTE: very expensive, lots of copies here
              val (cs, ls) = externalsValue(accs, locals, value)
              (cs, ls.appended(varName))
            } else (accs, locals)
          case fc: FunctionCall =>
            externalsValue(accs, locals, fc)
          case Return(value) =>
            externalsValue(accs, locals, value)
          case WhileLoop(loop) =>
            val (accN, localsN) = externalsValue(accs, locals, loop.condition)
            externalsStatements(accN, localsN, loop.body)
          case Expression(expr) =>
            externalsValue(accs, locals, expr)
          case If(ifBranch, elifBranches, elseBranch) =>
            val varsIf = externalsValue(accs, locals, ifBranch.condition)
            val ifAcc = externalsStatements(varsIf._1, varsIf._2, ifBranch.body)

            val res: (Seq[String], Seq[String]) =
              elifBranches.foldLeft(ifAcc)((a, br) =>
                val (acc, loc) = a
                val (acc1, loc1) = externalsValue(acc, loc, br.condition)
                externalsStatements(acc1, loc1, br.body)
              )

            elseBranch match {
              case Some(br) =>
                val (accs, locals) = res
                externalsStatements(accs, locals, br)
              case None =>
                res
            }
        }
      )
    ext
  }

  private def externalsOfValue(
      currentCaptures: Seq[String],
      value: Value
  ): Seq[String] =
    value match {
      case Identifier(name) =>
        if (!currentCaptures.contains(name))
          currentCaptures.appended(name)
        else currentCaptures
      case Wrapped(value) => externalsOfValue(currentCaptures, value)
      case FunctionCall(functionExpr, args) =>
        val fx = externalsOfValue(currentCaptures, functionExpr)
        args.foldLeft(fx)(externalsOfValue)
      case Function(args, body, _capt) =>
        val caps = allExternalIdentifiers(args, body)
        caps.flatMap(e => if (args.contains(e)) Seq() else Seq(e))
      case ArrayLiteral(elements) =>
        elements.foldLeft(currentCaptures)(externalsOfValue)
      case _: Value => currentCaptures
    }

  def lookup(id: Identifier): Option[Value] =
    this.captures.get(id.name)
end Capture

def evalFunctionCall(
    functionExpr: Value,
    callArgs: Seq[Value],
    scope: Scope
): Scope =
  val evaledCallArgs = callArgs.map(evalValue(_, scope).result.get)
  functionExpr match {
    case Identifier(identifier) =>
      if (identifier == "print") {
        printValues(evaledCallArgs, scope)
        print("\n")
        scope
      } else if (builtins.contains(identifier)) {
        val callArgsNew = evaledCallArgs.map { value =>
          interpreterdata.toDataObject(value)
        }
        val Some(func) = builtins.get(identifier): @unchecked
        assert(
          func.n_args == callArgs.length,
          s"function call: expected ${func.n_args} argument(s) but got ${callArgs.length}"
        )
        val result = func.function(callArgsNew)
        scope.returnValue(interpreterdata.toAstNode(result))
      } else {
        scope.lookupFunction(Identifier(identifier)) match {
          case Some(Function(args, body, c)) =>
            // TODO: merge the capture with the current scope
            val res =
              body.foldLeft(
                Scope(scope.withCapture(c.getOrElse(null)), args, callArgs)
              )(
                evalStatement
              )
            val Some(value) = res.result: @unchecked
            scope.returnValue(value)
          case None =>
            assert(
              false,
              s"function '$identifier' not found"
            )
        }
      }
    case Wrapped(value) =>
      evalFunctionCall(value, evaledCallArgs, scope)

    case Function(args, body, s) =>
      val res =
        body.foldLeft(
          Scope(scope.withCapture(s.getOrElse(null)), args, evaledCallArgs)
        )(
          evalStatement
        )
      val Some(value) = res.result: @unchecked
      scope.returnValue(value)

    case FunctionCall(functionExpr, args) =>
      val Some(Function(args1, body1, s)) =
        evalFunctionCall(functionExpr, args, scope).result: @unchecked
      val res = body1.foldLeft(
        Scope(scope.withCapture(s.getOrElse(null)), args1, evaledCallArgs)
      )(evalStatement)
      val Some(value) = res.result: @unchecked
      scope.returnValue(value)
  }

def evalReturn(value: Value, scope: Scope): Scope =
  if (scope.isGlobal) assert(false, "can not return from global scope")
  else
    value match {
      case id: Identifier =>
        (scope.result, scope.lookup(id)) match {
          case (None, Some(v)) => scope.returnValue(v)
          case (Some(v), _)    => scope.returnValue(v)
          case (None, None) =>
            assert(
              false,
              s"identifier '${id.name}' does not exist that could be returned"
            )
        }

      case f: Function =>
        val tmp = Function(f.args, f.body, Some(Capture(scope, f.args, f.body)))
        scope.returnValue(f)
      case va =>
        scope.result match {
          case None =>
            val Some(res) = evalValue(va, scope).result: @unchecked
            scope.returnValue(res)
          case Some(v) => scope.returnValue(v)
        }
    }

def evalStatement(
    scope: Scope,
    st: Statement
): Scope =
  // First we differentiate of what type the current statement is.
  // The types are given by the `statementP` parsing rule in the Parser file.
  // Our goal of this function obviously is to handle all statements. This can either be a definition/re-definition
  // of a variable. Then we want to update the Scope. Or loops, if-else, function calls, return (see statementP rule).
  if (scope.hasResult)
    scope
  else
    st match {
      case Assignment(name, value) =>
        // Assignments have the form variable = Value. See the `valueP` rule of the parser for the types that are assignable.
        // Our goal here is it to evaluate the right-hand side. Eg. x = 4+9, then we want to add the variable x to the
        // Scope with the value 13 as a number.
        val result = evalValue(value, scope)
        // NOTE: `.result` should allways exist. It indicates a bug in `evalValue` if it does not
        // The evalValue-function stores the newly calculated value in the Scope in the variable `result`. We need to
        // update the variable `name` with this new value.
        val Some(newValue) = result.result: @unchecked
        scope.update(Identifier(name), newValue)
      case FunctionCall(identifier, callArgs) =>
        evalFunctionCall(identifier, callArgs, scope)
      case Return(value) =>
        evalReturn(value, scope)
      case Expression(expr) =>
        val result = evalValue(expr, scope)
        val Some(return_value) = result.result: @unchecked
        result.returnValue(return_value)
      case If(ifBranch, elifBranches, elseBranch) => {
        evalIf(ifBranch, elifBranches, elseBranch, scope)
      }
      case WhileLoop(loop) =>
        evalWhileLoop(loop, scope)
    }

def evalWhileLoop(whileLoop: Branch, scope: Scope): Scope = {
  var currentScope = scope
  while (
    evalValue(whileLoop.condition, currentScope).result.contains(Bool(true))
  ) {
    currentScope =
      whileLoop.body.foldLeft(currentScope)((accScope, statement) => {
        if (accScope.hasResult)
          accScope // Early exit if result is set (like return statements)
        else evalStatement(accScope, statement)
      })
  }
  currentScope
}

def evalIf(
    initialBranch: Branch,
    elifBranches: Seq[Branch],
    elseBranch: Option[Seq[Statement]],
    scope: Scope
): Scope = {

  def evalBranch(branch: Branch, scope: Scope): Option[Scope] = {
    val result = evalValue(branch.condition, scope)
    result.result match {
      case Some(Bool(true)) =>
        Some(branch.body.foldLeft(scope)(evalStatement))
      case _ =>
        None
    }
  }

  // Check initial branch condition
  var conditionsMet = false
  evalBranch(initialBranch, scope) match {
    case Some(updatedScope) =>
      updatedScope // Return updated scope if the initial branch is true
    case None =>
      val finalScope = elifBranches.foldLeft(scope) { (currentScope, branch) =>
        evalBranch(branch, currentScope) match {
          case Some(updatedScope) =>
            conditionsMet = true
            updatedScope
          case None => currentScope
        }
      }

      if (conditionsMet) {
        return finalScope
      } else if (elseBranch.isEmpty) {
        return scope
      }

      // Evaluate the else branch if no conditions were met
      elseBranch match {
        case Some(statements) =>
          statements.foldLeft(finalScope)(evalStatement)
        case _ => finalScope
      }
  }
}

def evalValue(
    v: Value,
    scope: Scope
): Scope =
  v match {
    case Function(args, body, _) =>
      scope.returnValue(Function(args, body, Some(Capture(scope, args, body))))
    case FunctionCall(identifier, callArgs) =>
      evalFunctionCall(identifier, callArgs, scope)
    case BinaryOp(left, op, right) =>
      val left_result = evalValue(left, scope)
      val Some(new_left) = left_result.result: @unchecked
      val right_result = evalValue(right, scope)
      val Some(new_right) = right_result.result: @unchecked
      evalBinaryOp(op, new_left, new_right, scope)
    case UnaryOp(op, value) =>
      val Some(result) = evalValue(value, scope).result: @unchecked
      op match {
        case ArithmaticOp(Add) => scope.returnValue(result)
        case ArithmaticOp(Sub) =>
          result match {
            case n: Number =>
              scope.returnValue(Number(-n.value))
            case v =>
              assert(false, s"unary op: value case '$v' is not implemented")
          }
        case BooleanOp(Not) =>
          val tmp = result match {
            case Bool(value) => Bool(!value)
            case v =>
              assert(false, s"unary operator 'not' is not defined for '$v'")
          }
          scope.returnValue(tmp)
        case o => assert(false, s"unary op: op case '$o' is not implemented")
      }
    case StructureAccess(id, v) => {
      val returnVal: Value = scope.lookup(id) match {
        case Some(Dictionary(entries)) =>
          val result: Option[Value] = entries.foldLeft(None) { (acc, curr) =>
            acc match {
              case None =>
                val res = evalValue(curr.key, scope)
                val Some(value) = res.result: @unchecked
                val res2 = evalCompareOps(Eq, value, v, scope)
                res2.result match {
                  case Some(Bool(true)) =>
                    Some(curr.value)
                  case _ => None
                }
              case r => r
            }
          }
          result match {
            case Some(value) => value
            case None => assert(false, s"structure '${id.name}' does not exist")
          }
        case _ =>
          assert(false, s"no structure found by the name '${id.name}'")
      }
      scope.returnValue(returnVal)
    }
    case Identifier(name) =>
      scope.lookup(Identifier(name)) match {
        case Some(value) =>
          scope.returnValue(value)
        case None =>
          assert(false, s"identifier '$name' does not exist")
      }
    case Number(value) =>
      scope.returnValue(Number(value))
    case Bool(value) =>
      scope.returnValue(Bool(value))
    case Wrapped(value) =>
      evalValue(value, scope)
    case Dictionary(entries) =>
      scope.returnValue(Dictionary(entries))
    case err =>
      assert(false, f"TODO: not implemented '$err'")
  }

def evalBinaryOp(
    op: Operator,
    left: Value,
    right: Value,
    scope: Scope
): Scope = {
  op match
    case ArithmaticOp(ops) => evalArithmeticOps(ops, left, right, scope)
    case CompareOp(ops)    => evalCompareOps(ops, left, right, scope)
    case BooleanOp(ops)    => evalBooleanOps(ops, left, right, scope)
    case _ => throw new IllegalArgumentException("Binary operation invalid.")
}

def evalBooleanOps(
    op: BooleanOps,
    left: Value,
    right: Value,
    scope: Scope
): Scope = {
  // evaluate left and right value
  val Some(leftEval) = evalValue(left, scope).result: @unchecked
  val Some(rightEval) = evalValue(right, scope).result: @unchecked

  // if left or right is string.
  if (leftEval.isInstanceOf[Identifier] || rightEval.isInstanceOf[Identifier]) {
    assert(false, "No boolean operators allowed on strings")
  }

  // otherwise left and right are bools or numbers
  val result = op match {
    case And => (extractNumber(leftEval) > 0) && (extractNumber(rightEval) > 0)
    case Or  => (extractNumber(leftEval) > 0) || (extractNumber(rightEval) > 0)
    case _   => assert(false, "Unexpected comparison operation.")
  }

  scope.returnValue(Bool(result)) // Adding the result to the scope
}

def evalCompareOps(
    op: CompareOps,
    left: Value,
    right: Value,
    scope: Scope
): Scope = {
  // evaluate left and right value
  val Some(leftEval) = evalValue(left, scope).result: @unchecked
  val Some(rightEval) = evalValue(right, scope).result: @unchecked
  // if left or right is string.
  if (leftEval.isInstanceOf[Identifier] || rightEval.isInstanceOf[Identifier]) {
    op match {
      case Eq =>
        scope.returnValue(
          Bool(
            leftEval.asInstanceOf[Identifier].name == rightEval
              .asInstanceOf[Identifier]
              .name
          )
        )
      case NotEq =>
        scope.returnValue(
          Bool(
            leftEval.asInstanceOf[Identifier].name != rightEval
              .asInstanceOf[Identifier]
              .name
          )
        )
      case _ => assert(false, "On Strings, only == and != are allowed.")
    }
    return scope
  }

  // otherwise left and right are bools or numbers
  val result = op match {
    case Less      => extractNumber(leftEval) < extractNumber(rightEval)
    case LessEq    => extractNumber(leftEval) <= extractNumber(rightEval)
    case Greater   => extractNumber(leftEval) > extractNumber(rightEval)
    case GreaterEq => extractNumber(leftEval) >= extractNumber(rightEval)
    case Eq        => leftEval == rightEval
    case NotEq     => leftEval != rightEval
    case null      => assert(false, "Unexpected comparison operation.")
  }

  scope.returnValue(Bool(result)) // Adding the result to the scope
}

def evalArithmeticOps(
    op: ArithmaticOps,
    left: Value,
    right: Value,
    scope: Scope
): Scope = {
  // evaluate left and right value
  val resLeft = evalValue(left, scope)
  val Some(leftEval) = resLeft.result: @unchecked
  val resRight = evalValue(right, scope)
  val Some(rightEval) = resRight.result: @unchecked

  if (leftEval.isInstanceOf[Identifier] || rightEval.isInstanceOf[Identifier]) {
    assert(false, "No arithmetic operations of string allowed.")
  }

  val leftNumber = extractNumber(leftEval)
  val rightNumber = extractNumber(rightEval)
  // calculate arithmetic operation
  val result = op match {
    case Add  => leftNumber + rightNumber
    case Sub  => leftNumber - rightNumber
    case Mul  => leftNumber * rightNumber
    case Div  => leftNumber / rightNumber
    case Mod  => leftNumber % rightNumber
    case Expo => scala.math.pow(leftNumber, rightNumber)
    case null => assert(false, "Arithmetic operation is null")
  }
  scope.returnValue(Number(result)) // Adding the result to the scope
}

// Input: Number or Bool. Output: Double (true == 1, false == 0)
def extractNumber(value: Value): Double = value match {
  case Number(n) => n
  case Bool(b)   => if (b) 1.0 else 0.0
  case _         => assert(false, "Expected number or boolean in comparison.")
}

def printValues(values: Seq[Value], scope: Scope): Unit =
  val output = values
    .map(_.toString)
    .mkString(" ")
  print(output)
