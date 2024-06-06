import fastparse._
import fastparse.Parsed.Success
import fastparse.Parsed.Failure

class UnaryOperator extends munit.FunSuite {
  test("case '-5'") {
    val input = "-5"
    val expected = UnaryOp(ArithmaticOp(ArithmaticOps.Sub), Number(5))
    parse(input, valueUnaryOpP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }

  test("case '+5'") {
    val input = "+5"
    val expected = UnaryOp(ArithmaticOp(ArithmaticOps.Add), Number(5))
    parse(input, valueUnaryOpP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }

  test("case 'not 5'") {
    val input = "not 5"
    val expected = UnaryOp(BooleanOp(BooleanOps.Not), Number(5))
    parse(input, valueUnaryOpP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }

  test("case 'and 5' (should fail)") {
    val input = "and 5"
    parse(input, valueUnaryOpP(using _)) match {
      case Success(value, index) =>
        assert(false, "operator 'and' is a binay operator not a unary one")
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        assert(true)
    }
  }

  test("case 'not true ^ 5'") {
    val input = "not true ^ 5"
    val expected = UnaryOp(
      BooleanOp(BooleanOps.Not),
      BinaryOp(Bool(true), ArithmaticOp(ArithmaticOps.Expo), Number(5))
    )
    parse(input, valueP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }

  test("case '- 2 ^ 5'") {
    val input = "- 2 ^ 5"
    val expected = UnaryOp(
      ArithmaticOp(ArithmaticOps.Sub),
      BinaryOp(Number(2), ArithmaticOp(ArithmaticOps.Expo), Number(5))
    )
    parse(input, valueP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }

  test("case '- true + 5'") {
    val input = "- true + 5"
    val expected =
      BinaryOp(
        UnaryOp(ArithmaticOp(ArithmaticOps.Sub), Bool(true)),
        ArithmaticOp(ArithmaticOps.Add),
        Number(5)
      )
    parse(input, valueP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }

  test("case '5 + - true'") {
    val input = "5 + - true"
    val expected =
      BinaryOp(
        Number(5),
        ArithmaticOp(ArithmaticOps.Add),
        UnaryOp(ArithmaticOp(ArithmaticOps.Sub), Bool(true))
      )
    parse(input, valueP(using _)) match {
      case Success(value, index) =>
        assertEquals(value, expected)
        assertEquals(index, input.length, "input has not been parsed fully")
      case f: Failure =>
        val msg = f.trace().longAggregateMsg
        assert(
          false,
          f"unary expression parsing for test case '$input' failed\n  msg: $msg"
        )
    }
  }
}
