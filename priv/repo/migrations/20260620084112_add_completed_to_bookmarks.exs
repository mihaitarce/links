defmodule Links.Repo.Migrations.AddCompletedToBookmarks do
  use Ecto.Migration

  def change do
    alter table(:bookmarks) do
      add :completed, :boolean, null: false, default: false
    end
  end
end
