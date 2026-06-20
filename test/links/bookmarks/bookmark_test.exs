defmodule Links.Bookmarks.BookmarkTest do
  use ExUnit.Case, async: true

  alias Links.Bookmarks.Bookmark

  describe "changeset/2" do
    test "accepts urls up to 2048 characters" do
      url = "https://example.com/" <> String.duplicate("a", 2_048 - 20)

      assert %Ecto.Changeset{valid?: true} =
               Bookmark.changeset(%Bookmark{}, %{
                 url: url,
                 created_by_id: 1
               })
    end

    test "rejects urls longer than 2048 characters" do
      url = "https://example.com/" <> String.duplicate("a", 2_048 - 19)

      assert %Ecto.Changeset{valid?: false} =
               Bookmark.changeset(%Bookmark{}, %{
                 url: url,
                 created_by_id: 1
               })
    end

    test "derives a short title from long urls" do
      url = "https://www.example.com/" <> String.duplicate("path", 400)

      changeset = Bookmark.changeset(%Bookmark{}, %{url: url, created_by_id: 1})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :title) == "example.com"
      assert String.length(Ecto.Changeset.get_field(changeset, :url)) > 240
    end
  end

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
