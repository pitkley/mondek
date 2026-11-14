# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationStack do
  @moduledoc """
  A stable investigation owner shared by list, editor and direct detail hosts.

  Hosts pass their current local URL, raw URL params, current clock and optional
  typed initial/root identities. Keep this component's ID stable through patches.
  The host's OverviewPanel hook owns the existing stack/focus DOM mechanics.
  Only the active entity may mutate; rear snapshots never grant form authority.
  """
  use Phoenix.LiveComponent
  alias Mondek.Monitoring

  alias MondekWeb.{
    InvestigationEntity,
    InvestigationTrail,
    PanelStack,
    PreviewDetail,
    PreviewCoverage,
    NotificationDetail,
    ExecutionDetail,
    PreviewIncidentControls,
    PreviewIncidentDetail,
    PreviewResultDetail,
    RunnerDetail
  }

  @retained_limit 16
  @delivery_statuses [
    {"all", "All notifications"},
    {"unresolved", "Unresolved"},
    {"pending", "Pending"},
    {"retrying", "Retrying"},
    {"delivering", "Delivering"},
    {"exhausted", "Exhausted"},
    {"delivered", "Delivered"},
    {"superseded", "Superseded"}
  ]

  @impl true
  def mount(socket),
    do:
      {:ok, assign(socket, states: %{}, trail: [], root: nil, context: nil, limit_reached: false)}

  @impl true
  def update(assigns, socket) do
    previous_context = socket.assigns.context
    context = Map.get(assigns, :context, assigns.host)
    initial = Map.get(assigns, :initial, [])
    direct_root = InvestigationTrail.identity(Map.get(assigns, :root))
    trail = InvestigationTrail.resolve(assigns.params, initial)

    # A full-page presentation may promote the selected overlay without changing
    # the original host root or any retained entity authority.
    trail = if length(Enum.uniq(List.wrap(direct_root) ++ trail)) <= 6, do: trail, else: []
    page_identity = InvestigationTrail.from_token(assigns.params["page_entity"])
    promoted = if assigns.params["surface"] == "page" && page_identity in trail, do: page_identity
    root = promoted || direct_root
    index = if root, do: Enum.find_index(trail, &(&1 == root))
    prefix = if is_integer(index), do: Enum.take(trail, index + 1), else: []
    trail = if is_integer(index), do: Enum.drop(trail, index + 1), else: trail
    states = if context == previous_context, do: socket.assigns.states, else: %{}
    identities = Enum.uniq(List.wrap(direct_root) ++ List.wrap(root) ++ trail)
    new_count = Enum.count(identities, &(!Map.has_key?(states, &1)))
    limited = map_size(states) + new_count > @retained_limit

    {root, trail, identities} =
      if limited,
        do:
          {socket.assigns.root, socket.assigns.trail,
           Enum.uniq(List.wrap(socket.assigns.root) ++ socket.assigns.trail)},
        else: {root, trail, identities}

    active = List.last(trail) || root
    states = if is_nil(active), do: %{}, else: states

    states =
      Enum.reduce(identities, states, fn identity, acc ->
        state = Map.get(acc, identity, InvestigationEntity.new(identity))

        state =
          if identity == active || is_nil(state.data),
            do: InvestigationEntity.refresh(state, assigns.now, assigns.params),
            else: state

        Map.put(acc, identity, state)
      end)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       context: context,
       root: root,
       origin_root: direct_root,
       trail_prefix: if(limited, do: Map.get(socket.assigns, :trail_prefix, []), else: prefix),
       trail: trail,
       active: active,
       states: states,
       unavailable: Map.get(assigns, :unavailable, false),
       limit_reached: limited
     )}
  end

  @impl true
  def handle_event("recover_investigation", %{"snapshot" => token}, socket)
      when is_binary(token) and byte_size(token) <= 262_144 do
    with {:ok, %{context: context, states: recovered}} <-
           Phoenix.Token.verify(MondekWeb.Endpoint, "investigation-drafts-v1", token,
             max_age: 86_400
           ),
         true <- context == socket.assigns.context,
         true <- is_map(recovered) && map_size(recovered) <= @retained_limit,
         true <-
           Enum.all?(recovered, fn {identity, _} ->
             InvestigationTrail.identity(identity) == identity
           end) do
      states =
        Map.new(recovered, fn {identity, controls} ->
          state = Map.get(socket.assigns.states, identity, InvestigationEntity.new(identity))
          {identity, Map.merge(state, controls)}
        end)

      # Keep identities loaded from the current validated route even when the
      # recovered snapshot predates its last navigation. Recovery never writes.
      states = Map.merge(socket.assigns.states, states)

      if map_size(states) <= @retained_limit,
        do: {:noreply, assign(socket, states: states)},
        else: {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("recover_investigation", _, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) do
    identity = socket.assigns.active
    state = socket.assigns.states[identity]

    allowed =
      case identity do
        {kind, _} when kind in ~w(health loss) ->
          event in ~w(filter_incident_detail edit_acknowledgement review_control toggle_acknowledgement_replacement save_acknowledgement end_acknowledgement edit_retry_delivery retry_delivery)

        {"notification", _} ->
          event in ~w(edit_notification_retry retry_notification)

        _ ->
          false
      end

    if state && allowed && params["entity"] == InvestigationTrail.token(identity) do
      {:noreply, operate(socket, state, event, params)}
    else
      {:noreply, socket}
    end
  end

  defp operate(socket, %{identity: {"notification", _}} = state, "edit_notification_retry", %{
         "_id" => id,
         "reason" => reason
       }) do
    drafts =
      MondekWeb.NotificationRetry.keep_draft(
        state.retry_drafts,
        List.wrap(get_in(state.data || %{}, ["occurrence"])),
        id,
        reason
      )

    put_state(socket, %{state | retry_drafts: drafts})
  end

  defp operate(socket, %{identity: {"notification", _}} = state, "retry_notification", %{
         "_id" => id,
         "reason" => reason
       }) do
    detail = %{"occurrences" => List.wrap(get_in(state.data || %{}, ["occurrence"]))}

    apply_result(
      socket,
      state,
      PreviewIncidentControls.retry(detail, state.retry_drafts, id, reason)
    )
  end

  defp operate(socket, _state, "filter_incident_detail", %{"notification_status" => value}) do
    if List.keymember?(@delivery_statuses, value, 0),
      do:
        push_patch(socket,
          to:
            url(socket.assigns, socket.assigns.trail, %{
              "notification_status" => value,
              "notification_page" => nil
            })
        ),
      else: socket
  end

  defp operate(socket, state, "edit_acknowledgement", params) do
    state = %{state | draft: PreviewIncidentControls.draft(params)}
    # The recovered form carries its originally reviewed revisions. A reconnect
    # may recover values, but must not silently turn them into a fresh review.
    state =
      case {integer(params["_revision"]), integer(params["_attention_revision"])} do
        {revision, attention} when is_integer(revision) and is_integer(attention) ->
          %{state | review: %{"revision" => revision, "attention_revision" => attention}}

        _ ->
          state
      end

    put_state(socket, state)
  end

  defp operate(socket, state, "review_control", _) do
    incident = get_in(state, [:data, :incident])

    if incident && incident["status"] == "open",
      do:
        put_state(socket, %{
          state
          | review: PreviewIncidentControls.revision(incident),
            feedback: nil
        }),
      else: socket
  end

  defp operate(socket, state, "toggle_acknowledgement_replacement", _) do
    incident = get_in(state, [:data, :incident])

    if incident && Monitoring.acknowledgement_active?(incident),
      do: put_state(socket, %{state | replacing: !state.replacing, draft: %{}, feedback: nil}),
      else: socket
  end

  defp operate(
         socket,
         %{review: review, identity: {kind, id}} = state,
         "save_acknowledgement",
         params
       )
       when is_map(review),
       do: apply_result(socket, state, PreviewIncidentControls.save(kind, id, review, params))

  defp operate(socket, %{review: review, identity: {kind, id}} = state, "end_acknowledgement", _)
       when is_map(review),
       do:
         apply_result(
           socket,
           state,
           PreviewIncidentControls.finish(kind, id, review, state.data.incident)
         )

  defp operate(socket, state, "edit_retry_delivery", %{"_id" => id, "reason" => reason}) do
    drafts =
      MondekWeb.NotificationRetry.keep_draft(
        state.retry_drafts,
        state.data.detail["occurrences"] || [],
        id,
        reason
      )

    put_state(socket, %{state | retry_drafts: drafts})
  end

  defp operate(socket, state, "retry_delivery", %{"_id" => id, "reason" => reason}),
    do:
      apply_result(
        socket,
        state,
        PreviewIncidentControls.retry(state.data.detail, state.retry_drafts, id, reason)
      )

  defp operate(socket, _state, _event, _params), do: socket

  defp apply_result(socket, state, {changes, refresh?}) do
    names = %{
      control_review: :review,
      control_draft: :draft,
      control_replacing: :replacing,
      control_feedback: :feedback,
      delivery_feedback: :delivery_feedback,
      retry_drafts: :retry_drafts
    }

    state =
      Enum.reduce(changes, state, fn {key, value}, acc ->
        Map.put(acc, Map.fetch!(names, key), value)
      end)

    state =
      if refresh?,
        do: InvestigationEntity.refresh(state, socket.assigns.now, socket.assigns.params),
        else: state

    put_state(socket, state)
  end

  defp put_state(socket, state) do
    states = Map.put(socket.assigns.states, state.identity, state)

    if byte_size(recovery_snapshot(%{states: states, context: socket.assigns.context})) <= 131_072 do
      assign(socket, :states, states)
    else
      previous = socket.assigns.states[state.identity]

      feedback =
        {:error,
         "This investigation has too many draft values. Save or clear a draft before adding another."}

      assign(
        socket,
        :states,
        Map.put(socket.assigns.states, state.identity, %{previous | feedback: feedback})
      )
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil

  @impl true
  def render(assigns) do
    ancestors = if assigns.trail == [], do: [], else: Enum.drop(assigns.trail, -1)

    entries =
      Enum.with_index(ancestors, 1)
      |> Enum.map(fn {identity, count} ->
        state = assigns.states[identity]

        %{
          identity: identity,
          title: InvestigationEntity.title(state),
          kind: InvestigationEntity.kind(state),
          path: restore_view(url(assigns, Enum.take(assigns.trail, count)), state),
          state: state
        }
      end)

    assigns =
      assign(assigns,
        ancestors: entries,
        state: assigns.states[assigns.active],
        root_state: assigns.states[assigns.root],
        current: restore_view(url(assigns, assigns.trail), assigns.states[assigns.active]),
        recovery_snapshot: recovery_snapshot(assigns)
      )

    ~H"""
    <div
      id={@id}
      phx-target={@myself}
      data-investigation-owner
      data-active-entity={@active && InvestigationTrail.token(@active)}
    >
      <form
        id={@id <> "-recovery"}
        hidden
        phx-change="recover_investigation"
        phx-auto-recover="recover_investigation"
        phx-target={@myself}
      >
        <input type="hidden" name="snapshot" value={@recovery_snapshot} />
      </form>
      <p
        :if={
          @limit_reached || map_size(@states) >= 16 ||
            length(Enum.uniq(List.wrap(@origin_root) ++ @trail_prefix ++ List.wrap(@root) ++ @trail)) >=
              6
        }
        class="preview-empty"
        role="alert"
      >
        This investigation is full. Existing drafts are preserved.
        <.link :if={@active} navigate={canonical(@active)}>Start a new investigation from this evidence</.link>
      </p>
      <article
        :if={@root_state}
        id={
          case elem(@root_state.identity, 0) do
            "result" -> "preview-result-page"
            "runner" -> "runner-page"
            "notification" -> "notification-page"
            "execution" -> "execution-page"
            kind when kind in ~w(coverage diagnostic) -> "coverage-page-body"
            _ -> "incident-page"
          end
        }
        class="preview-incident-panel preview-incident-page pf-v6-c-card"
        inert={@trail != []}
      >
        <div class="pf-v6-c-card__body">
          <div class="preview-panel-tools">
            <.link patch={Map.get(assigns, :back, "/")} class="pf-v6-c-button pf-m-link">← {back_label(
              Map.get(assigns, :back, "/")
            )}</.link>
            <.link
              :if={@params["surface"] == "page"}
              patch={url(assigns, @trail, %{"surface" => nil, "page_entity" => nil})}
              class="pf-v6-c-button pf-m-link"
            >Open fly-over</.link>
          </div>
          <.entity_body
            state={@root_state}
            host_assigns={assigns}
            full_page={true}
            id_prefix={if @trail == [], do: "", else: "root-"}
          />
        </div>
      </article>
      <PreviewDetail.surface :if={!@state && @unavailable}>
        <div class="preview-panel-tools"><.link patch={@back} data-overview-close>Close</.link></div>
        <h2 id="overview-panel-title" tabindex="-1">Result unavailable</h2>
      </PreviewDetail.surface>
      <PanelStack.rear_cards entries={@ancestors} card_class="preview-incident-panel pf-v6-c-card">
        <:fallback :let={ancestor}>
          <div class="pf-v6-c-card__body">
            <.entity_body
              state={ancestor.state}
              host_assigns={assigns}
              full_page={false}
              id_prefix="rear-"
            />
          </div>
        </:fallback>
      </PanelStack.rear_cards>
      <PreviewDetail.surface
        :if={@state && @trail != []}
        path={@current}
        heading_id={
          if elem(@active, 0) in [
               "result",
               "runner",
               "notification",
               "execution",
               "coverage",
               "diagnostic"
             ],
             do: "overview-panel-title",
             else: "incident-heading"
        }
      >
        <div class="preview-panel-tools">
          <.link patch={back_path(assigns)} data-overview-close class="pf-v6-c-button pf-m-link">← {if length(
                                                                                                         @trail
                                                                                                       ) >
                                                                                                         1 ||
                                                                                                         @root,
                                                                                                       do:
                                                                                                         "Back one level",
                                                                                                       else:
                                                                                                         "Close"}</.link>
          <.link patch={page_path(assigns)} class="pf-v6-c-button pf-m-link">Open as page</.link>
        </div>
        <.entity_body state={@state} host_assigns={assigns} full_page={false} id_prefix="" />
      </PreviewDetail.surface>
    </div>
    """
  end

  defp entity_body(%{state: %{identity: {"result", _id}}} = assigns) do
    panel = assigns.state.data

    {configuration_path, configuration_patch} =
      editor_destination(
        assigns.host_assigns,
        panel && "/configuration/" <> panel.selected["assignment_id"]
      )

    {discovery_path, discovery_patch} =
      editor_destination(
        assigns.host_assigns,
        panel && "/checks/" <> panel.selected["id"] <> "/discovery"
      )

    {discovery_settings_path, discovery_settings_patch} =
      editor_destination(
        assigns.host_assigns,
        panel && "/configuration/discovery/" <> panel.selected["assignment_id"]
      )

    assigns =
      assign(assigns,
        discovery_settings_path: discovery_settings_path,
        discovery_settings_patch: discovery_settings_patch,
        panel: panel,
        configuration_path: configuration_path,
        configuration_patch: configuration_patch,
        discovery_path: discovery_path,
        discovery_patch: discovery_patch
      )

    ~H"""
    <PreviewResultDetail.detail
      :if={@panel}
      panel={@panel}
      now={@host_assigns.now}
      configuration_path={@configuration_path}
      configuration_patch={@configuration_patch}
      discovery_settings_path={@discovery_settings_path}
      discovery_settings_patch={@discovery_settings_patch}
      discovery_path={@discovery_path}
      discovery_patch={@discovery_patch}
      incident_path={fn id -> destination(@host_assigns, {"health", id}) end}
      peer_path={fn id -> destination(@host_assigns, {"result", id}) end}
      runner_path={fn id -> destination(@host_assigns, {"runner", id}) end}
      execution_path={fn id -> destination(@host_assigns, {"execution", id}) end}
      diagnostic_runner={@panel[:diagnostic_runner]}
      diagnostics_open={@host_assigns.params["diagnostics"] == "1"}
      current={@host_assigns.current}
      full_page={@full_page}
      full_result_path={if !@full_page, do: page_path(@host_assigns)}
      full_result_patch={true}
      heading_id={if @full_page, do: "full-result-heading", else: "overview-panel-title"}
      id_prefix={@id_prefix}
    />
    <h2 :if={!@panel} id="overview-panel-title" tabindex="-1">Result unavailable</h2>
    """
  end

  defp entity_body(%{state: %{identity: {kind, id}}} = assigns)
       when kind in ~w(coverage diagnostic) do
    assigns = assign(assigns, kind: kind, coverage_id: id)

    ~H"""
    <PreviewCoverage.body
      evidence={@state.data}
      kind={@kind}
      full_page={@full_page}
      id_prefix={@id_prefix}
      heading_id={if @full_page, do: "coverage-page-heading", else: "overview-panel-title"}
      current={@host_assigns.current}
      runner_path={fn id -> destination(@host_assigns, {"runner", id}) end}
      result_path={fn id -> destination(@host_assigns, {"result", id}) end}
      page_path={
        fn page ->
          url(@host_assigns, @host_assigns.trail, %{
            "coverage_entity" => @coverage_id,
            "coverage_observer_page" => to_string(page)
          })
        end
      }
    />
    """
  end

  defp entity_body(%{state: %{identity: {"execution", _id}}} = assigns) do
    data = assigns.state.data || %{}

    {configuration_path, configuration_patch} =
      editor_destination(
        assigns.host_assigns,
        if(data[:inspection], do: "/configuration/" <> data.inspection["assignment"]["id"])
      )

    assigns =
      assign(assigns,
        inspection: data[:inspection],
        runner: data[:runner],
        windows: data[:windows] || [],
        configuration_path: configuration_path || "/configuration",
        configuration_patch: configuration_patch
      )

    ~H"""
    <ExecutionDetail.body
      inspection={@inspection}
      runner={@runner}
      windows={@windows}
      now={@host_assigns.now}
      full_page={@full_page}
      id_prefix={@id_prefix}
      current={@host_assigns.current}
      result_path={fn id -> destination(@host_assigns, {"result", id}) end}
      incident_path={fn id -> destination(@host_assigns, {"health", id}) end}
      runner_path={fn id -> destination(@host_assigns, {"runner", id}) end}
      configuration_path={@configuration_path}
      configuration_patch={@configuration_patch}
    />
    """
  end

  defp entity_body(%{state: %{identity: {"notification", _}}} = assigns) do
    ~H"""
    <NotificationDetail.body
      inspection={@state.data}
      now={@host_assigns.now}
      full_page={@full_page}
      target={@host_assigns.myself}
      entity={InvestigationTrail.token(@state.identity)}
      retry_drafts={@state.retry_drafts}
      feedback={@state.delivery_feedback}
      id_prefix={@id_prefix}
      incident_path={fn identity -> destination(@host_assigns, identity) end}
      result_path={fn id -> destination(@host_assigns, {"result", id}) end}
      execution_path={fn id -> destination(@host_assigns, {"execution", id}) end}
      maintenance_path={fn id -> "/maintenance/" <> id end}
    />
    """
  end

  defp entity_body(%{state: %{identity: {"runner", _}}} = assigns) do
    ~H"""
    <RunnerDetail.body
      runner={@state.data}
      now={@host_assigns.now}
      full_page={@full_page}
      id_prefix={@id_prefix}
      heading_id={if @full_page, do: "runner-heading", else: "overview-panel-title"}
      current={@host_assigns.current}
      controller_url={Map.get(@host_assigns, :controller_url, MondekWeb.Endpoint.url())}
    />
    """
  end

  defp entity_body(assigns) do
    %{identity: {kind, _}, data: data} = assigns.state

    assigns =
      assign(assigns,
        kind: kind,
        detail: data.detail,
        incident: data.incident,
        delivery_statuses: @delivery_statuses
      )

    ~H"""
    <PreviewIncidentDetail.body
      incident={@incident}
      detail={@detail}
      kind={@kind}
      title={InvestigationEntity.title(@state)}
      type_label={InvestigationEntity.kind(@state)}
      now={@host_assigns.now}
      current={@host_assigns.current}
      id_prefix={@id_prefix}
      full_page={@full_page}
      control_review={@state.review}
      control_draft={@state.draft}
      control_replacing={@state.replacing}
      control_feedback={@state.feedback}
      delivery_feedback={@state.delivery_feedback}
      retry_drafts={@state.retry_drafts}
      maintenance_windows={@state.data.maintenance_windows}
      detail_filters={detail_filters(@host_assigns.params)}
      delivery_statuses={@delivery_statuses}
      target={@host_assigns.myself}
      entity={InvestigationTrail.token(@state.identity)}
      result_path={fn id -> destination(@host_assigns, {"result", id}) end}
      incident_path={fn id, _ -> destination(@host_assigns, {"health", id}) end}
      expected_path={fn id -> destination(@host_assigns, {"coverage", id}) end}
      page_path={
        fn param, page -> url(@host_assigns, @host_assigns.trail, %{param => to_string(page)}) end
      }
      filter_path={fn changes -> url(@host_assigns, @host_assigns.trail, changes) end}
    />
    """
  end

  defp recovery_snapshot(assigns) do
    states =
      Map.new(assigns.states, fn {identity, state} ->
        {identity, Map.take(state, [:review, :draft, :replacing, :retry_drafts, :view])}
      end)

    Phoenix.Token.sign(MondekWeb.Endpoint, "investigation-drafts-v1", %{
      context: assigns.context,
      states: states
    })
  end

  defp editor_destination(_, nil), do: {nil, false}

  defp editor_destination(assigns, path) do
    if URI.parse(assigns.host).path == path do
      {InvestigationTrail.path(assigns.host, [], %{"surface" => nil, "page_entity" => nil}), true}
    else
      {path <> "?" <> URI.encode_query(%{"return_to" => assigns.current}), false}
    end
  end

  defp detail_filters(params),
    do: %{
      "notification_status" => params["notification_status"] || "all",
      "member_page" => params["member_page"] || "1",
      "notification_page" => params["notification_page"] || "1",
      "healthy_page" => params["healthy_page"] || "1",
      "contributors" => params["contributors"] || "default"
    }

  defp destination(assigns, identity) do
    prefix_index = Enum.find_index(assigns.trail_prefix, &(&1 == identity))

    path =
      cond do
        identity == assigns.origin_root ->
          InvestigationTrail.path(assigns.host, [], %{"surface" => nil, "page_entity" => nil})

        is_integer(prefix_index) && identity != assigns.root ->
          InvestigationTrail.path(
            assigns.host,
            Enum.take(assigns.trail_prefix, prefix_index + 1),
            %{"surface" => nil, "page_entity" => nil}
          )

        !Map.has_key?(assigns.states, identity) && map_size(assigns.states) >= @retained_limit ->
          assigns.current

        identity not in Enum.uniq(
          List.wrap(assigns.origin_root) ++
              assigns.trail_prefix ++ List.wrap(assigns.root) ++ assigns.trail
        ) &&
            length(
              Enum.uniq(
                List.wrap(assigns.origin_root) ++
                    assigns.trail_prefix ++ List.wrap(assigns.root) ++ assigns.trail
              )
            ) >= 6 ->
          assigns.current

        true ->
          case InvestigationTrail.open(assigns.trail, identity, assigns.root) do
            {:ok, trail} -> url(assigns, trail)
            _ -> assigns.current
          end
      end

    restore_view(path, assigns.states[identity])
  end

  defp restore_view(path, %{identity: {"coverage", _}, view: view}) when map_size(view) > 0 do
    params = URI.decode_query(URI.parse(path).query || "")

    view =
      if view["coverage_observer_page"] in [nil, "1"],
        do: %{"coverage_entity" => nil, "coverage_observer_page" => nil},
        else: view

    InvestigationTrail.path(path, InvestigationTrail.resolve(params), view)
  end

  defp restore_view(path, _), do: path

  defp back_label("/runners" <> _), do: "Back to runners"
  defp back_label("/notifications" <> _), do: "Back to notifications"
  defp back_label("/coverage" <> _), do: "Back to coverage"
  defp back_label("/checks" <> _), do: "Back to checks"
  defp back_label("/incidents" <> _), do: "Back to incidents"
  defp back_label(_), do: "Back to overview"
  defp canonical({"coverage", id}), do: "/coverage/" <> id <> "/full"
  defp canonical({"diagnostic", id}), do: "/coverage/diagnostics/" <> id <> "/full"
  defp canonical({"execution", id}), do: "/executions/" <> id
  defp canonical({"notification", id}), do: "/notifications/" <> id <> "/full"
  defp canonical({"runner", id}), do: "/runners/" <> id <> "/full"
  defp canonical({"result", id}), do: "/results/" <> id <> "/full"
  defp canonical({kind, id}), do: "/incidents/" <> kind <> "/" <> id <> "/full"

  defp back_path(assigns) do
    if length(assigns.trail) == 1 && is_nil(assigns.root) do
      Map.get(assigns, :back, url(assigns, []))
    else
      previous = Enum.drop(assigns.trail, -1)
      identity = List.last(previous) || assigns.root
      restore_view(url(assigns, previous), assigns.states[identity])
    end
  end

  defp page_path(assigns),
    do:
      restore_view(
        url(assigns, assigns.trail, %{
          "surface" => "page",
          "page_entity" => InvestigationTrail.token(assigns.active)
        }),
        assigns.states[assigns.active]
      )

  defp url(assigns, trail, changes \\ %{}) do
    trail =
      if assigns.root && assigns.params["surface"] == "page",
        do: assigns.trail_prefix ++ trail,
        else: trail

    InvestigationTrail.path(assigns.host, trail, changes)
  end
end
