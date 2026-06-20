defmodule Links.Bookmarks.BookmarkTest do
  use ExUnit.Case, async: true

  alias Links.Bookmarks.Bookmark

  describe "display_host/1" do
    test "returns the host without a www prefix" do
      assert Bookmark.display_host("https://www.example.com/docs") == "example.com"
      assert Bookmark.display_host(%Bookmark{url: "https://example.org/path"}) == "example.org"
    end

    test "returns nil for invalid urls" do
      refute Bookmark.display_host("not-a-url")
      refute Bookmark.display_host(%Bookmark{url: nil})
    end
  end
end
