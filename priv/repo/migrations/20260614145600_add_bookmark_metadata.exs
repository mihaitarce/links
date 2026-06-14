defmodule Links.Repo.Migrations.AddBookmarkMetadata do
  use Ecto.Migration

  def change do
    alter table(:bookmarks) do
      add :page_title, :string
      add :favicon_data, :binary
      add :favicon_content_type, :string
      add :favicon_byte_size, :integer
      add :favicon_source_url, :text
      add :metadata_fetched_at, :utc_datetime
    end
  end
end
