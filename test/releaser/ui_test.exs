defmodule Releaser.UITest do
  use ExUnit.Case, async: true

  alias Releaser.UI

  describe "magenta/1" do
    test "wraps text with ANSI magenta and reset" do
      result = UI.magenta("hello")
      assert String.starts_with?(result, IO.ANSI.magenta())
      assert String.ends_with?(result, IO.ANSI.reset())
      assert result =~ "hello"
    end

    test "text appears between the ANSI sequences" do
      magenta = IO.ANSI.magenta()
      reset = IO.ANSI.reset()
      assert UI.magenta("hi") == "#{magenta}hi#{reset}"
    end

    test "empty string" do
      magenta = IO.ANSI.magenta()
      reset = IO.ANSI.reset()
      assert UI.magenta("") == "#{magenta}#{reset}"
    end
  end

  describe "blue/1" do
    test "wraps text with ANSI blue and reset" do
      result = UI.blue("world")
      assert String.starts_with?(result, IO.ANSI.blue())
      assert String.ends_with?(result, IO.ANSI.reset())
      assert result =~ "world"
    end

    test "text appears between the ANSI sequences" do
      blue = IO.ANSI.blue()
      reset = IO.ANSI.reset()
      assert UI.blue("bar") == "#{blue}bar#{reset}"
    end

    test "empty string" do
      blue = IO.ANSI.blue()
      reset = IO.ANSI.reset()
      assert UI.blue("") == "#{blue}#{reset}"
    end
  end

  describe "ANSI stripping" do
    test "stripping magenta/1 leaves bare text" do
      stripped = Regex.replace(~r/\e\[[0-9;]*m/, UI.magenta("foo"), "")
      assert stripped == "foo"
    end

    test "stripping blue/1 leaves bare text" do
      stripped = Regex.replace(~r/\e\[[0-9;]*m/, UI.blue("bar"), "")
      assert stripped == "bar"
    end
  end
end
