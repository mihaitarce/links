defmodule Links.Repo.Migrations.EnforceBookmarkTitleNotNull do
  use Ecto.Migration

  def change do
    execute "UPDATE bookmarks SET title = url WHERE title IS NULL OR title = ''", ""

    alter table(:bookmarks) do
      modify :title, :string, null: false, from: {:string, null: true}
    end
  end
end
