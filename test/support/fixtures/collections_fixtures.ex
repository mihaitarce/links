defmodule Links.CollectionsFixtures do
  @moduledoc """
  Test helpers for collection and bookmark records.
  """

  alias Links.Accounts.Scope
  alias Links.Collections

  def collection_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "Collection #{System.unique_integer([:positive])}"})
    {:ok, collection} = Collections.create_collection(scope, attrs)
    collection
  end

  def bookmark_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "Bookmark #{System.unique_integer([:positive])}",
        url: "https://example.com/#{System.unique_integer([:positive])}"
      })

    {:ok, bookmark} = Collections.create_inbox_bookmark(scope, attrs)
    bookmark
  end
end
