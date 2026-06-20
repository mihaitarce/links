defmodule Links.Bookmarks.Bookmark do
  use Ecto.Schema
  import Ecto.Changeset

  alias Links.Accounts.User
  alias Links.Collections.Collection

  schema "bookmarks" do
    field :title, :string
    field :url, :string
    field :description, :string
    field :position, :integer, default: 0
    field :page_title, :string
    field :favicon_data, :binary
    field :favicon_content_type, :string
    field :favicon_byte_size, :integer
    field :favicon_source_url, :string
    field :metadata_fetched_at, :utc_datetime

    belongs_to :collection, Collection
    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:title, :url, :description, :position, :collection_id, :created_by_id])
    |> normalize_title()
    |> validate_required([:title, :url, :created_by_id])
    |> validate_length(:title, min: 1, max: 240)
    |> validate_length(:url, min: 3, max: 2_048)
    |> validate_url()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:collection_id)
    |> foreign_key_constraint(:created_by_id)
  end

  def metadata_changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [
      :page_title,
      :favicon_data,
      :favicon_content_type,
      :favicon_byte_size,
      :favicon_source_url,
      :metadata_fetched_at
    ])
    |> validate_length(:page_title, max: 240)
    |> validate_length(:favicon_content_type, max: 120)
    |> validate_length(:favicon_source_url, max: 2_048)
    |> validate_number(:favicon_byte_size, greater_than_or_equal_to: 0)
  end

  defp normalize_title(changeset) do
    case {get_field(changeset, :title), get_field(changeset, :url)} do
      {title, _url} when is_binary(title) and title != "" ->
        changeset

      {_title, url} when is_binary(url) ->
        put_change(changeset, :title, url)

      _ ->
        changeset
    end
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      uri = URI.parse(url)

      if uri.scheme in ["http", "https"] && is_binary(uri.host) && uri.host != "" do
        []
      else
        [url: "must be an http or https URL"]
      end
    end)
  end

  def display_host(%__MODULE__{url: url}), do: display_host(url)

  def display_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        strip_www_prefix(host)

      _ ->
        nil
    end
  end

  def display_host(_), do: nil

  defp strip_www_prefix(host) do
    case host do
      "www." <> rest -> rest
      "WWW." <> rest -> rest
      _ -> host
    end
  end
end
