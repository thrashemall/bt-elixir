defmodule Bittorrent.Client do
  @moduledoc """
  Client in charge of downloading / uploading all the Files for a given BitTorrent
  """
  require Logger
  use GenServer
  alias Bittorrent.{Torrent, PeerDownloader}

  @blocks_in_progress_path "_blocks"
  @tmp_extension ".tmp"
  @max_connections 50

  def in_progress_path(), do: @blocks_in_progress_path

  # Client

  def start_link(%Torrent{} = torrent) do
    GenServer.start_link(__MODULE__, torrent, name: __MODULE__)
  end

  def request_peer() do
    GenServer.call(__MODULE__, {:request_peer})
  end

  def return_peer(address) do
    GenServer.call(__MODULE__, {:return_peer, address})
  end

  def request_piece(piece_set) do
    GenServer.call(__MODULE__, {:request_piece, piece_set})
  end

  def piece_downloaded(piece_index, data) do
    GenServer.call(__MODULE__, {:piece_downloaded, piece_index, data})
  end

  # Server (callbacks)

  @impl true
  def init(%Torrent{} = torrent) do
    max_conns = min(:queue.len(torrent.peers), @max_connections)

    torrent = restore_from_progress(torrent)

    Enum.reduce(1..max_conns, torrent, fn _, torrent ->
      start_peer_downloader(torrent)
    end)

    {:ok, torrent}
  end

  @impl true
  def handle_call({:request_peer}, _from, torrent) do
    {assigned_peer, state} = handle_request_peer(torrent)

    {:reply, {:ok, assigned_peer}, state}
  end

  @impl true
  def handle_call({:return_peer, address}, _from, torrent) do
    peers_with_returned = :queue.in(address, torrent.peers)

    {:reply, :ok,
     %Torrent{
       torrent
       | peers: peers_with_returned
     }}
  end

  @impl true
  def handle_call({:request_piece, piece_set}, _from, torrent) do
    pieces = Torrent.pieces_we_need_that_peer_has(torrent, piece_set)
    piece = pieces |> Enum.shuffle() |> List.first()

    if piece do
      {:reply, piece,
       %Torrent{torrent | in_progress_pieces: [piece.number, torrent.in_progress_pieces]}}
    else
      {:noreply, torrent}
    end
  end

  @impl true
  def handle_call({:piece_downloaded, piece_index, data}, _from, torrent) do
    Logger.debug("Piece downloaded: #{piece_index}")

    :ok =
      File.write(
        Path.join([
          torrent.output_path,
          @blocks_in_progress_path,
          "#{piece_index}#{@tmp_extension}"
        ]),
        data
      )

    piece_size = byte_size(data)

    {:noreply,
     Torrent.update_with_piece_downloaded(
       torrent,
       piece_index,
       piece_size
     )}
  end

  # Utilities

  defp handle_request_peer(torrent) do
    case :queue.out(torrent.peers) do
      {{_value, assigned_peer}, remaining_peers} ->
        {assigned_peer,
         %Torrent{
           torrent
           | peers: remaining_peers
         }}

      {:empty, _} ->
        {nil, torrent}
    end
  end

  defp restore_from_progress(torrent) do
    blocks_path = Path.join([torrent.output_path, @blocks_in_progress_path])
    tmp_extension_index = -(String.length(@tmp_extension) + 1)

    {:ok, existing_blocks} = File.ls(blocks_path)

    Logger.info("We already downloaded #{length(existing_blocks)} blocks :)")

    existing_blocks
    |> Enum.map(&String.slice(&1, 0..tmp_extension_index))
    |> Enum.map(&String.to_integer/1)
    |> Enum.reduce(torrent, fn piece_index, torrent ->
      # TODO read block size
      Torrent.update_with_piece_downloaded(torrent, piece_index, 0)
    end)
  end

  defp start_peer_downloader(%Torrent{} = torrent) do
    case handle_request_peer(torrent) do
      {nil, torrent} ->
        torrent

      {peer, torrent} ->
        {:ok, pid} =
          PeerDownloader.start_link(%PeerDownloader.State{
            info_sha: torrent.info_sha,
            peer_id: torrent.peer_id,
            address: peer
          })

        %Torrent{
          torrent
          | peer_downloader_pids: [pid | torrent.peer_downloader_pids]
        }
    end
  end
end
