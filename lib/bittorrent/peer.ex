defmodule Bittorrent.Peer do
  @moduledoc """
  The guts of meaningfully communicating with a Peer we are connected to; leverage the protocol to get a peer
  to send us the pieces we need.
  """

  alias Bittorrent.Peer.{Protocol, Address}
  require Logger

  defmodule State do
    defstruct [
      # About them
      :name,
      :reserved,
      :info_hash,
      :id,
      # Assume new peers have nothing until we know otherwise
      piece_set: MapSet.new(),
      # Their feelings for us
      choked: true,
      interested: false,
      # Our feelings for them
      interested_in: false,
      choking: true,
      # Stats
      requests_in_flight: 0
    ]

    def have_piece(peer, piece) do
      %Bittorrent.Peer.State{peer | piece_set: MapSet.put(peer.piece_set, piece)}
    end
  end

  @max_requests_in_flight 10
  @max_connection_frequency 30

  def connect(address, info_sha, peer_id) do
    Logger.info(
      "Connecting: #{to_string(address.ip)} #{address.port} #{address.last_connected_at}"
    )

    sleep_if_connected_recently(address.last_connected_at)

    with {:ok, socket} <-
           :gen_tcp.connect(
             address.ip,
             address.port,
             [:binary, packet: :raw, active: false, nodelay: true],
             3000
           ),
         {:ok, peer} <-
           Protocol.send_and_receive_handshake(
             info_sha,
             peer_id,
             socket
           ) do
      {:ok, peer, socket}
    else
      error -> error
    end
  end

  def download_loop(piece, peer, socket, timeout \\ :infinity) do
    with {:ok, peer} <- Protocol.receive_message(peer, socket, timeout),
         {:ok, peer} <- receive_until_buffer_empty(peer, socket),
         {:ok, peer} <- request_until_pipeline_full(peer, socket) do
      download_loop(piece, peer, socket)
    else
      error -> error
    end
  end

  defp receive_until_buffer_empty(peer, socket) do
    case Protocol.receive_message(peer, socket, 0) do
      {:ok, peer} ->
        receive_until_buffer_empty(peer, socket)

      {:error, :timeout} ->
        {:ok, peer}

      error ->
        error
    end
  end

  # If we are choking we cannot send messages until we tell the peer we are unchoked
  defp request_until_pipeline_full(%State{choking: true} = peer, socket) do
    Protocol.send_unchoke(peer, socket)
  end

  # If the peer is choked there is no point sending messages, as they will be discarded
  defp request_until_pipeline_full(%State{choked: false} = peer, socket) do
    case Bittorrent.Client.request_piece(peer) do
      nil ->
        Protocol.send_not_interested(peer, socket)

      request ->
        case ensure_interested(peer, socket) do
          {:ok, peer} ->
            ensure_requests_saturated(peer, socket, request)

          error ->
            error
        end
    end
  end

  defp request_until_pipeline_full(%State{} = peer, _socket), do: {:ok, peer}

  defp ensure_interested(%State{interested_in: true} = peer, _socket), do: {:ok, peer}

  defp ensure_interested(%State{interested_in: false} = peer, socket) do
    Protocol.send_interested(peer, socket)
  end

  defp ensure_requests_saturated(%State{requests_in_flight: reqs} = peer, socket, request)
       when reqs < @max_requests_in_flight do
    case Protocol.send_request(peer, socket, request) do
      {:ok, peer} ->
        request_until_pipeline_full(peer, socket)

      error ->
        error
    end
  end

  defp ensure_requests_saturated(peer, _socket, _request), do: {:ok, peer}

  defp sleep_if_connected_recently(nil), do: nil

  defp sleep_if_connected_recently(connected_at) do
    now = DateTime.utc_now()
    seconds_since_connection = DateTime.diff(now, connected_at, :second)

    unless(seconds_since_connection > @max_connection_frequency) do
      sleep_for =
        round(@max_connection_frequency - seconds_since_connection + :random.uniform() * 10)

      Logger.debug("Connected Too Recently: sleeping for #{sleep_for} seconds")
      Process.sleep(sleep_for * 1000)
    end
  end
end
