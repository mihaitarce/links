# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Seeds the first (single) user account with nested collections and demo links.

import Ecto.Query

alias Links.Accounts
alias Links.Accounts.Scope
alias Links.Bookmarks.Bookmark
alias Links.Collections
alias Links.Collections.Collection
alias Links.Repo

demo_links = [
  # inbox
  %{title: "Hacker News", url: "https://news.ycombinator.com", inbox: true},
  %{title: "Lobsters", url: "https://lobste.rs", inbox: true},
  %{title: "PostgreSQL Docs", url: "https://www.postgresql.org/docs/", inbox: true},
  %{title: "Tailwind CSS", url: "https://tailwindcss.com", inbox: true},
  %{title: "DaisyUI", url: "https://daisyui.com", inbox: true},
  # reading list
  %{
    title: "Phoenix Guides",
    url: "https://hexdocs.pm/phoenix/overview.html",
    collection: "Reading List"
  },
  %{
    title: "LiveView Docs",
    url: "https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html",
    collection: "Reading List"
  },
  %{title: "Ecto Docs", url: "https://hexdocs.pm/ecto/Ecto.html", collection: "Reading List"},
  %{
    title: "SortableJS",
    url: "https://sortablejs.github.io/Sortable/",
    collection: "Reading List"
  },
  # work > phoenix
  %{title: "Hex", url: "https://hex.pm", collection: "Work", subcollection: "Phoenix"},
  %{
    title: "Elixir Forum",
    url: "https://elixirforum.com",
    collection: "Work",
    subcollection: "Phoenix"
  },
  %{title: "Fly.io", url: "https://fly.io", collection: "Work", subcollection: "Phoenix"},
  %{
    title: "Dashbit Blog",
    url: "https://dashbit.co/blog",
    collection: "Work",
    subcollection: "Phoenix"
  },
  # work > tools
  %{title: "GitHub", url: "https://github.com", collection: "Work", subcollection: "Tools"},
  %{title: "Linear", url: "https://linear.app", collection: "Work", subcollection: "Tools"},
  %{title: "Figma", url: "https://www.figma.com", collection: "Work", subcollection: "Tools"},
  # work (root)
  %{title: "Notion", url: "https://www.notion.so", collection: "Work"},
  %{title: "Slack", url: "https://slack.com", collection: "Work"},
  # inspiration
  %{
    title: "A List Apart",
    url: "https://alistapart.com",
    collection: "Inspiration"
  },
  %{
    title: "Smashing Magazine",
    url: "https://www.smashingmagazine.com",
    collection: "Inspiration"
  },
  %{title: "CSS-Tricks", url: "https://css-tricks.com", collection: "Inspiration"},
  # extra inbox (scrolling)
  %{title: "Reddit", url: "https://www.reddit.com", inbox: true},
  %{title: "ArXiv", url: "https://arxiv.org", inbox: true},
  # archive
  %{title: "Internet Archive", url: "https://archive.org", collection: "Archive"},
  %{title: "Wayback Machine", url: "https://web.archive.org", collection: "Archive"},
  %{
    title: "Old Side Project",
    url: "https://example.com/old-project",
    collection: "Archive",
    subcollection: "Old Projects"
  },
  %{
    title: "Retired Blog",
    url: "https://example.com/retired-blog",
    collection: "Archive",
    subcollection: "Old Projects"
  },
  %{
    title: "2019 Conference Notes",
    url: "https://example.com/conf-2019",
    collection: "Archive",
    subcollection: "Old Projects"
  },
  # podcasts
  %{title: "Changelog", url: "https://changelog.com/podcast", collection: "Podcasts"},
  %{title: "Syntax FM", url: "https://syntax.fm", collection: "Podcasts"},
  %{title: "ShopTalk Show", url: "https://shoptalkshow.com", collection: "Podcasts"}
]

case Repo.one(from u in Accounts.User, order_by: [asc: u.id], limit: 1) do
  nil ->
    IO.puts("No users found. Register an account first, then re-run seeds.")

  user ->
    scope = Scope.for_user(user)

    Repo.delete_all(from b in Bookmark, where: b.created_by_id == ^user.id)
    Repo.delete_all(from c in Collection, where: c.owner_id == ^user.id)

    {:ok, reading} = Collections.create_collection(scope, %{title: "Reading List"})
    {:ok, work} = Collections.create_collection(scope, %{title: "Work"})
    {:ok, inspiration} = Collections.create_collection(scope, %{title: "Inspiration"})

    {:ok, phoenix} =
      Collections.create_collection(scope, %{title: "Phoenix", parent_id: work.id})

    {:ok, tools} =
      Collections.create_collection(scope, %{title: "Tools", parent_id: work.id})

    {:ok, archive} = Collections.create_collection(scope, %{title: "Archive"})
    {:ok, podcasts} = Collections.create_collection(scope, %{title: "Podcasts"})

    {:ok, old_projects} =
      Collections.create_collection(scope, %{title: "Old Projects", parent_id: archive.id})

    collection_ids = %{
      "Reading List" => reading.id,
      "Work" => work.id,
      "Inspiration" => inspiration.id,
      "Archive" => archive.id,
      "Podcasts" => podcasts.id,
      "Work/Phoenix" => phoenix.id,
      "Work/Tools" => tools.id,
      "Archive/Old Projects" => old_projects.id
    }

    resolve_collection_id = fn link ->
      cond do
        link[:inbox] ->
          nil

        link[:subcollection] ->
          Map.fetch!(collection_ids, "#{link.collection}/#{link.subcollection}")

        true ->
          Map.fetch!(collection_ids, link.collection)
      end
    end

    Enum.each(demo_links, fn link ->
      attrs = %{
        title: link.title,
        url: link.url,
        description: "Demo bookmark seeded for #{user.email}."
      }

      if link[:inbox] do
        {:ok, _} = Collections.create_inbox_bookmark(scope, attrs)
      else
        {:ok, _} =
          Collections.create_bookmark(
            scope,
            Map.put(attrs, :collection_id, resolve_collection_id.(link))
          )
      end
    end)

    inbox_count = length(Enum.filter(demo_links, & &1[:inbox]))
    collection_count = length(demo_links) - inbox_count
    collection_total = map_size(collection_ids)

    IO.puts("""
    Seeded demo data for #{user.email}:
      - #{collection_total} collections (including nested folders)
      - #{inbox_count} inbox links
      - #{collection_count} collection links
      - #{length(demo_links)} links total
    """)
end
