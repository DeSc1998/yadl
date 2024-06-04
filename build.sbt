val scala3Version = "3.4.1"
val fastparse = "com.lihaoyi" %% "fastparse" % "3.1.0"

lazy val root = project
  .in(file("."))
  .settings(
    name := "yadl",
    version := "0.1.0",
    scalaVersion := scala3Version,
    libraryDependencies += "org.scalameta" %% "munit" % "0.7.29" % Test,
    libraryDependencies += fastparse
  )