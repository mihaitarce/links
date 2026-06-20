defmodule Links.Workers.FetchBookmarkMetadataWorkerTest do
  use Links.DataCase, async: true

  import Links.AccountsFixtures
  import Links.CollectionsFixtures

  alias Links.Collections
  alias Links.Workers.FetchBookmarkMetadataWorker

  setup context do
    Req.Test.set_req_test_from_context(context)
    Application.put_env(:links, :metadata_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:links, :metadata_req_options)
    end)

    :ok
  end

  test "decodes html entities in fetched page titles" do
    scope = user_scope_fixture()

    bookmark =
      bookmark_fixture(scope, %{
        url: "https://93.184.216.34/articles/tom-and-jerry"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/articles/tom-and-jerry" ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(
            200,
            """
            <html><head><title>Tom &amp; Jerry &#8212; Home</title></head><body></body></html>
            """
          )

        "/favicon.ico" ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)

    job = %Oban.Job{
      args: %{"bookmark_id" => bookmark.id},
      attempt: 1,
      max_attempts: 3
    }

    assert :ok = FetchBookmarkMetadataWorker.perform(job)

    assert Collections.get_bookmark!(bookmark.id).page_title == "Tom & Jerry — Home"
  end
end
