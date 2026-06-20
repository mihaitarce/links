defmodule LinksWeb.BaseUrlTest do
  use ExUnit.Case, async: true

  alias LinksWeb.BaseUrl

  test "normalizes a path prefix" do
    assert BaseUrl.normalize_path("/links") == "/links"
    assert BaseUrl.normalize_path("links") == "/links"
  end

  test "normalizes root and empty values to /" do
    assert BaseUrl.normalize_path("/") == "/"
    assert BaseUrl.normalize_path("") == nil
    assert BaseUrl.normalize_path(nil) == nil
  end

  test "strips a trailing slash" do
    assert BaseUrl.normalize_path("/links/") == "/links"
  end
end
