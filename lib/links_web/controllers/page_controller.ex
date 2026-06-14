defmodule LinksWeb.PageController do
  use LinksWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
