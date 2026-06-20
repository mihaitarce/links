defmodule Links.Repo.Migrations.RenameBookmarkPageTitleToTitle do
  use Ecto.Migration

  def change do
    execute """
    UPDATE bookmarks
    SET title = page_title
    WHERE page_title IS NOT NULL AND page_title != ''
    """,
            ""

    alter table(:bookmarks) do
      remove :page_title
    end
  end
end
