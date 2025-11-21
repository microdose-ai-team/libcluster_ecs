defmodule Cluster.EcsClusterInfo do
  @moduledoc """
  The goal of this module is to get us the following information:

  %{node_name => {{127,0,0,1} = ip, port}}

  for all the nodes in our ECS cluster.
  """

  use GenServer
  require Logger

  @refresh_timeout 10_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec get_nodes() ::
          %{(node_name :: String.t()) => {ip :: tuple(), port :: integer()}} | no_return()
  def get_nodes() do
    GenServer.call(__MODULE__, :get_nodes)
  end

  @impl true
  def init(config) do
    set_refresh()

    state = set_config(config, %{})

    nodes = case my_get_nodes(state) do
      {:ok, nodes} ->
        nodes
      _ ->
        init(config)
    end

    {:ok, state |> Map.put(:nodes, nodes)}
  end

  @impl true
  def handle_call(:get_nodes, _from, state) do
    {:reply, Map.get(state, :nodes, %{}), state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {:ok, nodes} = my_get_nodes(state)

    set_refresh()
    {:noreply, state |> Map.put(:nodes, nodes)}
  end

  defp set_refresh() do
    Process.send_after(self(), :refresh, @refresh_timeout)
  end

  defp set_config(config, state) do
    region = Keyword.fetch!(config, :region)
    cluster_name = Keyword.fetch!(config, :cluster_name)
    service_name = Keyword.fetch!(config, :service_name) |> List.wrap()
    app_prefix = Keyword.fetch!(config, :app_prefix)
    container_port = Keyword.fetch!(config, :container_port)

    state
    |> Map.put(:region, region)
    |> Map.put(:cluster_name, cluster_name)
    |> Map.put(:service_name, service_name)
    |> Map.put(:app_prefix, app_prefix)
    |> Map.put(:container_port, container_port)
  end

  defp my_get_nodes(state) do
    region = state.region
    cluster_name = state.cluster_name
    service_name = state.service_name
    app_prefix = state.app_prefix
    container_port = state.container_port

    with {:ok, list_service_body} <- list_services(cluster_name, region),
         {:ok, service_arns} <- extract_service_arns(list_service_body),
         {:ok, task_arns} <-
           get_tasks_for_services(cluster_name, region, service_arns, service_name),
         {:ok, desc_task_body} <- describe_tasks(cluster_name, task_arns, region),
         {:ok, task_ips} <- get_ips(desc_task_body, container_port) do
      {:ok,
       Map.new(task_ips, fn task_ip ->
         {node_name(task_ip, app_prefix), {task_ip, container_port}}
       end)}
    else
      err ->
        Logger.warn(fn -> "Error #{inspect(err)} while determining nodes in cluster via ECS" end)

        {:error, []}
    end
  end

  defp get_tasks_for_services(cluster_name, region, service_arns, service_names) do
    Enum.reduce(service_names, {:ok, []}, fn service_name, acc ->
      case acc do
        {:ok, acc_tasks} ->
          with(
            {:ok, service_arn} <- find_service_arn(service_arns, service_name),
            {:ok, list_task_body} <- list_tasks(cluster_name, service_arn, region),
            {:ok, task_arns} <- extract_task_arns(list_task_body)
          ) do
            {:ok, acc_tasks ++ task_arns}
          end

        other ->
          other
      end
    end)
  end

  defp log_aws(response, request_type) do
    Logger.debug("ExAws #{request_type} response: #{inspect(response)}")
    response
  end

  defp list_services(cluster_name, region) do
    params = %{
      "cluster" => cluster_name
    }

    query("ListServices", params)
    |> ExAws.request(region: region)
    |> log_aws("ListServices")
    |> list_services(cluster_name, region, [])
  end

  defp list_services(
         {:ok, %{"nextToken" => next_token, "serviceArns" => service_arns}},
         cluster_name,
         region,
         accum
       )
       when not is_nil(next_token) do
    params = %{
      "cluster" => cluster_name,
      "nextToken" => next_token
    }

    query("ListServices", params)
    |> ExAws.request(region: region)
    |> log_aws("ListServices")
    |> list_services(cluster_name, region, accum ++ service_arns)
  end

  defp list_services({:ok, %{"serviceArns" => service_arns}}, _cluster_name, _region, accum) do
    {:ok, %{"serviceArns" => accum ++ service_arns}}
  end

  defp list_services({:error, message}, _cluster_name, _region, _accum) do
    {:error, message}
  end

  defp list_tasks(cluster_name, service_arn, region) do
    params = %{
      "cluster" => cluster_name,
      "serviceName" => service_arn,
      "desiredStatus" => "RUNNING"
    }

    query("ListTasks", params)
    |> ExAws.request(region: region)
    |> log_aws("ListTasks")
  end

  defp describe_tasks(cluster_name, task_arns, region) do
    params = %{
      "cluster" => cluster_name,
      "tasks" => task_arns
    }

    query("DescribeTasks", params)
    |> ExAws.request(region: region)
    |> log_aws("DescribeTasks")
  end

  defp describe_container_instances(cluster_name, container_arns, region) do
    params = %{
      "cluster" => cluster_name,
      "containerInstances" => container_arns
    }

    query("DescribeContainerInstances", params)
    |> ExAws.request(region: region)
    |> log_aws("DescribeContainerInstances")
  end

  defp describe_ec2_instances(instance_ids, region) do
    ExAws.EC2.describe_instances(instance_ids: instance_ids)
    |> ExAws.request(region: region)
    |> log_aws("EC2:DescribeInstances")
  end

  @namespace "AmazonEC2ContainerServiceV20141113"
  defp query(action, params) do
    ExAws.Operation.JSON.new(
      :ecs,
      %{
        data: params,
        headers: [
          {"accept-encoding", "identity"},
          {"x-amz-target", "#{@namespace}.#{action}"},
          {"content-type", "application/x-amz-json-1.1"}
        ]
      }
    )
  end

  defp extract_task_arns(%{"taskArns" => arns}), do: {:ok, arns}
  defp extract_task_arns(_), do: {:error, "unknown task arns response"}

  defp extract_service_arns(%{"serviceArns" => arns}), do: {:ok, arns}
  defp extract_service_arns(_), do: {:error, "unknown service arns response"}

  defp find_service_arn(service_arns, service_name) when is_list(service_arns) do
    with {:ok, regex} <- Regex.compile(service_name) do
      service_arns
      |> Enum.find(&Regex.match?(regex, &1))
      |> case do
        nil ->
          Logger.error("no service matching #{service_name} found")
          {:error, "no service matching #{service_name} found"}

        arn ->
          {:ok, arn}
      end
    end
  end

  defp find_service_arn(_, _), do: {:error, "no service arns returned"}

  defp get_ips(%{"tasks" => tasks},  container_port) do
    arns_ports =
      tasks
      |> Enum.flat_map(fn t ->
        Map.get(t, "containers")
        |> Enum.map(fn c ->
          Map.get(c, "networkInterfaces")
          |> Enum.map(fn ni ->
            ni["privateIpv4Address"]
          end)
        end)
      end)
    {:ok, arns_ports}
  end

  defp node_name(ip, app_prefix) do
    :"#{app_prefix}@#{ip}"
  end
end
