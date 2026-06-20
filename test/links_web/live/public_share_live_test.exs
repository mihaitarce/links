defmodule LinksWeb.PublicShareLiveTest do
  use LinksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Links.AccountsFixtures
  import Links.CollectionsFixtures

  alias Links.Collections

  describe "public share page" do
    test "renders a shared collection tree for anonymous users", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Public Reading"})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Public Docs",
          url: "https://example.com/docs",
          collection_id: collection.id
        })

      {:ok, bookmark} =
        Collections.update_bookmark_metadata(bookmark, %{
          favicon_data: <<1, 2, 3>>,
          favicon_content_type: "image/png",
          favicon_byte_size: 3
        })

      assert {:ok, share} = Collections.create_public_share(scope, collection)

      {:ok, lv, html} = live(conn, ~p"/share/#{share.token}")

      assert html =~ "Public Reading"
      assert html =~ "Public Docs"
      assert html =~ ~s(href="https://example.com/docs")
      assert html =~ "data:image/png;base64,#{Base.encode64(<<1, 2, 3>>)}"
      refute html =~ ~s(/bookmarks/#{bookmark.id}/favicon)
      assert has_element?(lv, "#bookmark-#{bookmark.id}")
      refute has_element?(lv, "#collection-#{collection.id}")
    end

    test "shows unavailable message for invalid tokens", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/share/not-a-valid-token")

      assert html =~ "Shared collection unavailable"
    end

    test "updates when bookmarks change and when the share is revoked", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Live Public"})

      assert {:ok, share} = Collections.create_public_share(scope, collection)
      {:ok, lv, html} = live(conn, ~p"/share/#{share.token}")

      refute html =~ "Fresh Link"

      {:ok, _bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Fresh Link",
          url: "https://example.com/fresh",
          collection_id: collection.id
        })

      assert render(lv) =~ "Fresh Link"

      assert {:ok, _share} = Collections.revoke_public_share(scope, share)

      assert render(lv) =~ "Shared collection unavailable"
    end
  end
end
