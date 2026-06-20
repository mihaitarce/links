defmodule LinksWeb.PublicShareUrlTest do
  use ExUnit.Case, async: true

  alias LinksWeb.PublicShareUrl

  @token String.duplicate("a", 32)

  test "parses a public share URL on the default path" do
    assert {:ok, @token} = PublicShareUrl.parse("http://localhost:4000/share/#{@token}")
    assert {:ok, @token} = PublicShareUrl.parse("http://127.0.0.1:4000/share/#{@token}/")
    assert {:ok, @token} = PublicShareUrl.parse("https://example.com/share/#{@token}?ref=1")
  end

  test "parses a public share URL with a configured base path" do
    previous = Application.get_env(:links, LinksWeb.Endpoint)

    Application.put_env(
      :links,
      LinksWeb.Endpoint,
      Keyword.put(previous || [], :url, host: "localhost", path: "/links")
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:links, LinksWeb.Endpoint, previous)
      else
        Application.delete_env(:links, LinksWeb.Endpoint)
      end
    end)

    assert {:ok, @token} = PublicShareUrl.parse("http://localhost:4000/links/share/#{@token}")
  end

  test "returns error for non-share URLs and invalid tokens" do
    assert :error = PublicShareUrl.parse("https://example.com/article")
    assert :error = PublicShareUrl.parse("http://localhost:4000/share/short")
    assert :error = PublicShareUrl.parse("")
  end
end
