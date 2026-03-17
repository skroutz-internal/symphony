defmodule SymphonyElixir.SessionTailTest do
  @moduledoc """
  Tests that the pi-codex-shim tails the pi session JSONL file and forwards
  each entry to Symphony as a frontend-stream event.
  """

  use SymphonyElixir.TestSupport

  test "shim forwards session JSONL entries as frontend-stream events" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-session-tail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "ST-1")
      repo_root = Path.expand("../../..", __DIR__)
      fake_pi = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace)

      # Fake pi:
      #   1. Parses the --session <path> flag from its args
      #   2. Responds to thread/start (2nd line) and turn/start ACK (3rd line)
      #   3. Writes two pi session entries to the session file
      #   4. Emits agent_end to close the turn
      #
      # The shim should tail the session file and send each line as
      # {"method":"frontend-stream","params":<entry>} to Symphony's stdin.
      session_entry_1 =
        Jason.encode!(%{
          "type" => "session",
          "version" => 3,
          "id" => "test-session-abc",
          "timestamp" => "2026-01-01T00:00:00.000Z",
          "cwd" => "/tmp/test"
        })

      session_entry_2 =
        Jason.encode!(%{
          "type" => "message",
          "id" => "msg-001",
          "parentId" => nil,
          "timestamp" => "2026-01-01T00:00:01.000Z",
          "message" => %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "tail test"}]
          }
        })

      agent_end = Jason.encode!(%{"type" => "agent_end", "messages" => []})

      File.write!(fake_pi, """
      #!/bin/sh
      # Parse --session <path> from args
      session_file=""
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "--session" ]; then
          session_file="$arg"
        fi
        prev="$arg"
      done

      # The shim sends exactly one message to pi: {"type":"prompt","message":"..."}
      # Read it, write session entries to the JSONL, then emit agent_end.
      while IFS= read -r _line; do
        printf '%s\\n' '#{session_entry_1}' >> "$session_file"
        sleep 0.05
        printf '%s\\n' '#{session_entry_2}' >> "$session_file"
        sleep 0.05
        printf '%s\\n' '#{agent_end}'
        exit 0
      done
      """)

      File.chmod!(fake_pi, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "cd #{repo_root} && PI_BIN=#{fake_pi} node ./pi-codex-shim.ts"
      )

      issue = %Issue{
        id: "issue-session-tail",
        identifier: "ST-1",
        title: "Session tail forwarding",
        description: "Verify shim tails session JSONL and forwards as frontend-stream",
        state: "In Progress",
        url: "https://example.org/issues/ST-1",
        labels: []
      }

      test_pid = self()
      on_message = fn msg -> send(test_pid, {:msg, msg}) end

      assert {:ok, _} = AppServer.run(workspace, "tail test", issue, on_message: on_message)

      # Both session entries should arrive as :frontend_stream events,
      # payload carries the full method envelope; the pi entry is in "params"
      assert_receive {:msg,
                      %{
                        event: :frontend_stream,
                        payload: %{"method" => "frontend-stream", "params" => %{"type" => "session", "id" => "test-session-abc"}}
                      }},
                     10_000

      assert_receive {:msg,
                      %{
                        event: :frontend_stream,
                        payload: %{"method" => "frontend-stream", "params" => %{"type" => "message", "id" => "msg-001"}}
                      }},
                     10_000
    after
      File.rm_rf(test_root)
    end
  end
end
