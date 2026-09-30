// test_socketio_poc.cpp — sioxx connectivity POC (realtime M0, T0.1b).
//
// Env-gated: set WB_SIOXX_POC_ENDPOINT (e.g. "localhost:8790") to run against
// a live realtime service implementing the /board namespace contract. The
// service-restart case additionally requires WB_SIOXX_POC_RECONNECT=1 because
// it expects an operator to stop and restart the node service mid-run. When
// the variables are unset or empty the cases SKIP so local and CI runs without
// a service stay green.
//
// Matrix (T0.1b):
//   a) /board connect with an auth payload + board:session identity snapshot;
//   b) acks — board:ping {ok, serverTime}, board:echo {ok, echo};
//   c) broadcast — two clients in one board room, sender excluded;
//   d) direct — B -> A by userId, only the target receives board:directed;
//   e1) unreachable endpoint — bounded failure + back-off schedule evidence;
//   e2) service stop/start — automatic reconnect + repeated /board handshake
//       (operator-paced, gated by WB_SIOXX_POC_RECONNECT);
//   f) volatile — sioxx 0.3.0 exposes no droppable send API (verified against
//      its sources; roadmap-only), so M1 relies on the application-level
//      hysteresis queue (realtime collaboration design doc §5.4).
//
// Desktop-only: WASM builds do not fetch sioxx (see third_party/CMakeLists.txt).
#if !defined(__EMSCRIPTEN__)

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include <catch2/catch_test_macros.hpp>

#include <sioxx/sioxx.hpp>

namespace
{

using namespace std::chrono_literals;

std::string GetEnv(const char* name)
{
  const char* raw = std::getenv(name);
  return raw != nullptr ? std::string(raw) : std::string();
}

bool IsBlank(const std::string& value)
{
  return value.find_first_not_of(" \t\r\n") == std::string::npos;
}

std::string NormalizeEndpoint(const std::string& endpoint)
{
  if (endpoint.find("://") != std::string::npos)
  {
    return endpoint;
  }
  return "http://" + endpoint;
}

// Socket.IO delivers event/ack arguments as a JSON array; tolerate a bare
// object as well (single-argument convenience shape).
const sioxx::message* FirstArgument(const sioxx::message& data)
{
  if (data.is_array() && !data.empty())
  {
    return &data[0];
  }
  return &data;
}

std::string ObjectString(const sioxx::message& data, const char* field)
{
  const sioxx::message* value = FirstArgument(data);
  return value->is_object() ? value->value(field, std::string()) : std::string();
}

// Polls `done` until it returns true or the timeout expires (bounded waits).
template <typename Predicate>
bool WaitForCondition(Predicate done, std::chrono::milliseconds timeout)
{
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!done())
  {
    if (std::chrono::steady_clock::now() >= deadline)
    {
      return false;
    }
    std::this_thread::sleep_for(20ms);
  }
  return true;
}

// One-shot capture for emit-with-ack replies. Shared ownership keeps a late
// reply safe even after the awaiting test case gave up (the callback may run
// on a worker thread; the socket keeps the callback until it fires or dies).
// Always create via std::make_shared: Callback() relies on shared_from_this().
struct AckCapture : std::enable_shared_from_this<AckCapture>
{
  std::atomic<bool> received{false};

  std::mutex mutex;
  sioxx::message payload;

  sioxx::socket::ack_callback Callback()
  {
    auto self = shared_from_this();
    return [self](sioxx::message data)
    {
      {
        std::lock_guard<std::mutex> lock(self->mutex);
        self->payload = std::move(data);
      }
      self->received = true;
    };
  }

  bool Wait(std::chrono::milliseconds timeout)
  {
    return WaitForCondition([this] { return received.load(); }, timeout);
  }

  bool Ok()
  {
    std::lock_guard<std::mutex> lock(mutex);
    const sioxx::message* value = FirstArgument(payload);
    return value->is_object() && value->value("ok", false);
  }

  std::string StringField(const char* field)
  {
    std::lock_guard<std::mutex> lock(mutex);
    return ObjectString(payload, field);
  }

  bool NumberField(const char* field, double& out)
  {
    std::lock_guard<std::mutex> lock(mutex);
    const sioxx::message* value = FirstArgument(payload);
    if (!value->is_object())
    {
      return false;
    }
    const auto it = value->find(field);
    if (it == value->end() || !it->is_number())
    {
      return false;
    }
    out = it->get<double>();
    return true;
  }

  std::string Dump()
  {
    std::lock_guard<std::mutex> lock(mutex);
    return payload.dump();
  }
};

// Collects every incoming payload for one event name (same ownership rules as
// AckCapture).
struct EventLog : std::enable_shared_from_this<EventLog>
{
  std::mutex mutex;
  std::vector<sioxx::message> events;

  sioxx::socket::event_listener Listener()
  {
    auto self = shared_from_this();
    return [self](const std::string&, sioxx::message data)
    {
      std::lock_guard<std::mutex> lock(self->mutex);
      self->events.push_back(std::move(data));
    };
  }

  std::size_t Size()
  {
    std::lock_guard<std::mutex> lock(mutex);
    return events.size();
  }

  sioxx::message First()
  {
    std::lock_guard<std::mutex> lock(mutex);
    return events.empty() ? sioxx::message() : events.front();
  }
};

// Thread-safe lifecycle wrapper around one sioxx client on /board. Listeners
// only record observable state; test cases poll it with bounded waits.
struct PocClient
{
  explicit PocClient(sioxx::client_options options) : options(std::move(options))
  {
  }

  ~PocClient()
  {
    try
    {
      Stop();
    }
    catch (...)
    {
      // A POC teardown error must not mask the test verdict.
    }
  }

  void Start(const std::string& uri, const std::string& board_id)
  {
    client = std::make_unique<sioxx::client>(options);

    client->set_open_listener([this] { engineio_open = true; });
    client->set_fail_listener([this] { ++fail_count; });
    client->set_close_listener(
      [this](const std::string& reason)
      {
        std::lock_guard<std::mutex> lock(mutex);
        last_close_reason = reason;
        ++close_count;
      });
    client->set_error_listener(
      [this](const std::string& message)
      {
        std::lock_guard<std::mutex> lock(mutex);
        last_error = message;
        if (errors.size() < 32)
        {
          errors.push_back(message);
        }
      });
    client->set_reconnect_listener(
      [this](unsigned attempt, unsigned delay_ms)
      {
        std::lock_guard<std::mutex> lock(mutex);
        reconnect_plan.emplace_back(attempt, delay_ms);
      });

    sioxx::message auth = sioxx::message::object();
    auth["boardId"] = board_id;
    auth["clientVersion"] = "1.0.0";

    // Registering the socket before connect() lets client_impl auto-CONNECT it
    // on every Engine.IO open, including reconnects.
    board = client->socket("/board", std::move(auth));
    board->on_connect([this] { ++connect_count; });
    board->on_disconnect([this](const std::string&) { ++disconnect_count; });
    board->on("board:session",
              [this](const std::string&, sioxx::message data)
              {
                const sioxx::message* value = FirstArgument(data);
                std::lock_guard<std::mutex> lock(mutex);
                ++session_count;
                if (value->is_object())
                {
                  user_id = value->value("userId", std::string());
                  auth_mode = value->value("authMode", std::string());
                }
              });

    client->connect(uri);
  }

  void Stop()
  {
    if (client)
    {
      client->sync_close();
    }
  }

  std::string UserId()
  {
    std::lock_guard<std::mutex> lock(mutex);
    return user_id;
  }

  std::string AuthMode()
  {
    std::lock_guard<std::mutex> lock(mutex);
    return auth_mode;
  }

  std::string LastCloseReason()
  {
    std::lock_guard<std::mutex> lock(mutex);
    return last_close_reason;
  }

  // board:join + ack {ok:true, ...joined} (needed before room broadcasts).
  bool JoinBoard(const std::string& board_id, std::chrono::milliseconds timeout)
  {
    auto ack = std::make_shared<AckCapture>();
    sioxx::message payload = sioxx::message::object();
    payload["boardId"] = board_id;
    board->emit("board:join", payload, ack->Callback());
    return ack->Wait(timeout) && ack->Ok();
  }

  sioxx::client_options options;
  std::unique_ptr<sioxx::client> client;
  std::shared_ptr<sioxx::socket> board;

  std::atomic<bool> engineio_open{false};
  std::atomic<int> connect_count{0};
  std::atomic<int> disconnect_count{0};
  std::atomic<int> session_count{0};
  std::atomic<int> close_count{0};
  std::atomic<int> fail_count{0};

  std::mutex mutex;
  std::string user_id;
  std::string auth_mode;
  std::string last_close_reason;
  std::string last_error;
  std::vector<std::string> errors;
  std::vector<std::pair<unsigned, unsigned>> reconnect_plan;
};

// Waits for Engine.IO open + namespace CONNECT + the board:session snapshot.
bool WaitForEstablished(PocClient& c, std::chrono::milliseconds timeout)
{
  const bool ok = WaitForCondition(
    [&c]
    {
      return c.engineio_open.load() && c.connect_count.load() >= 1 &&
             c.session_count.load() >= 1;
    },
    timeout);
  if (!ok)
  {
    std::cout << "[poc] not established: open=" << c.engineio_open.load()
              << " connect=" << c.connect_count.load()
              << " session=" << c.session_count.load()
              << " close=" << c.close_count.load() << " fail=" << c.fail_count.load()
              << std::endl;
  }
  return ok;
}

// f) Volatile (droppable) send probe ----------------------------------------
// sioxx 0.3.0 ships no volatile send: the public API has no droppable-emit
// call and the sources contain none ("optional volatile events" appear only in
// the roadmap section of its docs). The desktop substitute is the M1
// application-level hysteresis queue (keep the newest frame per message kind).
// This sentinel flags an upstream upgrade that introduces a conventional
// volatile_emit so the fallback plan can be revisited. Best-effort probe: an
// upstream API under a different name will not trip it.
template <typename T, typename = void>
struct HasConventionalVolatileEmit : std::false_type
{
};

template <typename T>
struct HasConventionalVolatileEmit<
  T, std::void_t<decltype(std::declval<T&>().volatile_emit(std::declval<std::string>(),
                                                           std::declval<sioxx::message>()))>>
  : std::true_type
{
};

static_assert(!HasConventionalVolatileEmit<sioxx::socket>::value,
              "sioxx now exposes volatile_emit; revisit the M1 hysteresis-queue fallback");

}  // namespace

TEST_CASE("socketio POC: /board connect, session identity, ping and echo acks",
          "[integration][socketio][poc]")
{
  const std::string endpoint = GetEnv("WB_SIOXX_POC_ENDPOINT");
  if (endpoint.empty() || IsBlank(endpoint))
  {
    SKIP("WB_SIOXX_POC_ENDPOINT is not set - skipping live Socket.IO POC");
  }
  const std::string uri = NormalizeEndpoint(endpoint);
  std::cout << "[poc] connecting to " << uri << " (namespace /board)" << std::endl;

  PocClient c(sioxx::client_options{});
  c.Start(uri, "poc");

  // a) namespace /board connects with the auth payload.
  REQUIRE(WaitForCondition([&] { return c.engineio_open.load(); }, 10s));
  REQUIRE(WaitForEstablished(c, 10s));
  REQUIRE_FALSE(c.UserId().empty());
  REQUIRE_FALSE(c.AuthMode().empty());
  std::cout << "[poc] session identity: userId=" << c.UserId()
            << " authMode=" << c.AuthMode() << std::endl;

  // b) board:ping -> ack {ok:true, serverTime}.
  auto ping = std::make_shared<AckCapture>();
  c.board->emit("board:ping", sioxx::message::object(), ping->Callback());
  REQUIRE(ping->Wait(5s));
  REQUIRE(ping->Ok());
  double server_time = 0.0;
  REQUIRE(ping->NumberField("serverTime", server_time));
  REQUIRE(server_time > 0.0);
  std::cout << "[poc] board:ping ack: " << ping->Dump() << std::endl;

  // b) board:echo -> ack {ok:true, echo:"T0.1b-poc"}.
  auto echo = std::make_shared<AckCapture>();
  sioxx::message echo_payload = sioxx::message::object();
  echo_payload["payload"] = "T0.1b-poc";
  c.board->emit("board:echo", echo_payload, echo->Callback());
  REQUIRE(echo->Wait(5s));
  REQUIRE(echo->Ok());
  REQUIRE(echo->StringField("echo") == "T0.1b-poc");
  std::cout << "[poc] board:echo ack: " << echo->Dump() << std::endl;
}

TEST_CASE("socketio POC: same-room broadcast excludes the sender (two clients)",
          "[integration][socketio][poc]")
{
  const std::string endpoint = GetEnv("WB_SIOXX_POC_ENDPOINT");
  if (endpoint.empty() || IsBlank(endpoint))
  {
    SKIP("WB_SIOXX_POC_ENDPOINT is not set - skipping live Socket.IO POC");
  }
  const std::string uri = NormalizeEndpoint(endpoint);

  PocClient a(sioxx::client_options{});
  PocClient b(sioxx::client_options{});
  a.Start(uri, "poc-broadcast");
  b.Start(uri, "poc-broadcast");
  REQUIRE(WaitForEstablished(a, 15s));
  REQUIRE(WaitForEstablished(b, 15s));
  REQUIRE(a.JoinBoard("poc-broadcast", 5s));
  REQUIRE(b.JoinBoard("poc-broadcast", 5s));

  auto a_broadcasts = std::make_shared<EventLog>();
  auto b_broadcasts = std::make_shared<EventLog>();
  a.board->on("board:broadcast", a_broadcasts->Listener());
  b.board->on("board:broadcast", b_broadcasts->Listener());

  // c) A emits; the service broadcasts to the room excluding the sender.
  auto echo = std::make_shared<AckCapture>();
  sioxx::message echo_payload = sioxx::message::object();
  echo_payload["payload"] = "T0.1b-c-broadcast";
  a.board->emit("board:echo", echo_payload, echo->Callback());
  REQUIRE(echo->Wait(5s));
  REQUIRE(echo->Ok());

  REQUIRE(WaitForCondition([&] { return b_broadcasts->Size() >= 1; }, 5s));
  const sioxx::message event = b_broadcasts->First();
  REQUIRE(ObjectString(event, "from") == a.UserId());
  REQUIRE(ObjectString(event, "payload") == "T0.1b-c-broadcast");
  std::cout << "[poc] B received board:broadcast " << event.dump() << std::endl;

  // Sender-exclusion: settle briefly, then require no copy on A.
  std::this_thread::sleep_for(1s);
  REQUIRE(a_broadcasts->Size() == 0);
  std::cout << "[poc] A received 0 broadcasts (sender exclusion verified)"
            << std::endl;
}

TEST_CASE("socketio POC: direct message routes only to the target userId",
          "[integration][socketio][poc]")
{
  const std::string endpoint = GetEnv("WB_SIOXX_POC_ENDPOINT");
  if (endpoint.empty() || IsBlank(endpoint))
  {
    SKIP("WB_SIOXX_POC_ENDPOINT is not set - skipping live Socket.IO POC");
  }
  const std::string uri = NormalizeEndpoint(endpoint);

  PocClient a(sioxx::client_options{});
  PocClient b(sioxx::client_options{});
  a.Start(uri, "poc-direct");
  b.Start(uri, "poc-direct");
  REQUIRE(WaitForEstablished(a, 15s));
  REQUIRE(WaitForEstablished(b, 15s));

  auto a_directed = std::make_shared<EventLog>();
  auto b_directed = std::make_shared<EventLog>();
  a.board->on("board:directed", a_directed->Listener());
  b.board->on("board:directed", b_directed->Listener());

  // d) B directs a message to A's userId.
  auto ack = std::make_shared<AckCapture>();
  sioxx::message direct = sioxx::message::object();
  direct["toUserId"] = a.UserId();
  direct["payload"] = "T0.1b-d-direct";
  b.board->emit("board:direct", direct, ack->Callback());
  REQUIRE(ack->Wait(5s));
  REQUIRE(ack->Ok());

  REQUIRE(WaitForCondition([&] { return a_directed->Size() >= 1; }, 5s));
  const sioxx::message event = a_directed->First();
  REQUIRE(ObjectString(event, "from") == b.UserId());
  REQUIRE(ObjectString(event, "toUserId") == a.UserId());
  REQUIRE(ObjectString(event, "payload") == "T0.1b-d-direct");
  std::cout << "[poc] A received board:directed " << event.dump() << std::endl;

  // Target-only: settle briefly, then require no copy on the sender.
  std::this_thread::sleep_for(1s);
  REQUIRE(b_directed->Size() == 0);
  std::cout << "[poc] B received 0 directed messages (target-only verified)"
            << std::endl;
}

TEST_CASE("socketio POC: unreachable endpoint fails bounded with back-off schedule",
          "[integration][socketio][poc]")
{
  // Same gating as the live cases so the whole [poc] set runs (or SKIPs)
  // together.
  const std::string endpoint = GetEnv("WB_SIOXX_POC_ENDPOINT");
  if (endpoint.empty() || IsBlank(endpoint))
  {
    SKIP("WB_SIOXX_POC_ENDPOINT is not set - skipping live Socket.IO POC");
  }

  sioxx::client_options options;
  options.reconnect_attempts = 3;
  options.reconnect_delay = std::chrono::milliseconds(200);
  options.reconnect_delay_max = std::chrono::milliseconds(1000);
  options.reconnect_randomization_factor = 0.0;

  // Port 1 on loopback: nothing can listen there, so the handshake fails fast
  // and deterministically (connection refused). Note sioxx falls back from
  // WebSocket to HTTP long-polling after the first failure; polling failures
  // surface as transport close, which is what drives the reconnect schedule.
  PocClient dead(options);
  dead.Start("http://127.0.0.1:1", "poc-dead");
  std::cout << "[poc] probing unreachable endpoint http://127.0.0.1:1 ..."
            << std::endl;

  const bool exhausted =
    WaitForCondition([&] { return dead.fail_count.load() >= 1; }, 20s);

  std::vector<std::pair<unsigned, unsigned>> plan;
  std::vector<std::string> errors;
  {
    std::lock_guard<std::mutex> lock(dead.mutex);
    plan = dead.reconnect_plan;
    errors = dead.errors;
  }
  for (const std::string& message : errors)
  {
    std::cout << "[poc] error: " << message << std::endl;
  }
  for (const auto& [attempt, delay_ms] : plan)
  {
    std::cout << "[poc] reconnect scheduled: attempt=" << attempt
              << " delayMs=" << delay_ms << std::endl;
  }
  std::cout << "[poc] final opened=" << (dead.client->opened() ? "true" : "false")
            << " failEvents=" << dead.fail_count.load() << std::endl;

  REQUIRE(exhausted);                    // back-off attempts ran out -> fail event
  REQUIRE_FALSE(dead.client->opened());  // never reaches an open session
  REQUIRE_FALSE(errors.empty());         // errors were surfaced
  REQUIRE_FALSE(plan.empty());           // a back-off schedule was observed
  REQUIRE(plan.front().second > 0);
  for (std::size_t i = 1; i < plan.size(); ++i)
  {
    REQUIRE(plan[i].first > plan[i - 1].first);     // 0-based attempt index rises
    REQUIRE(plan[i].second >= plan[i - 1].second);  // delay never shrinks
  }
}

TEST_CASE("socketio POC: service restart triggers automatic reconnect and re-handshake",
          "[integration][socketio][poc][poc_reconnect]")
{
  const std::string endpoint = GetEnv("WB_SIOXX_POC_ENDPOINT");
  if (endpoint.empty() || IsBlank(endpoint))
  {
    SKIP("WB_SIOXX_POC_ENDPOINT is not set - skipping live Socket.IO POC");
  }
  if (GetEnv("WB_SIOXX_POC_RECONNECT") != "1")
  {
    SKIP("set WB_SIOXX_POC_RECONNECT=1 and stop/start the node service mid-run "
         "to execute the operator-paced reconnect case");
  }
  const std::string uri = NormalizeEndpoint(endpoint);

  sioxx::client_options options;
  options.reconnect_attempts = 1000;  // effectively unbounded for this case
  options.reconnect_delay = std::chrono::milliseconds(500);
  options.reconnect_delay_max = std::chrono::milliseconds(2000);
  options.reconnect_randomization_factor = 0.2;

  PocClient c(options);
  c.Start(uri, "poc-reconnect");
  REQUIRE(WaitForEstablished(c, 15s));
  REQUIRE(c.JoinBoard("poc-reconnect", 5s));
  std::cout << "[poc-reconnect] connected; userId=" << c.UserId()
            << " sessionCount=" << c.session_count.load() << std::endl;

  // e2 phase 1: the operator stops the node service now.
  std::cout << "[poc-reconnect] PHASE 1/2: stop the node service now "
            << "(waiting up to 120s for the drop)" << std::endl;
  REQUIRE(WaitForCondition([&] { return c.disconnect_count.load() >= 1; }, 120s));
  std::cout << "[poc-reconnect] service drop observed (closeCount="
            << c.close_count.load() << " reason=\"" << c.LastCloseReason() << "\")"
            << std::endl;

  // e2 phase 2: the operator restarts the node service now; sioxx reconnects
  // on its own and client_impl re-CONNECTs every registered namespace socket.
  std::cout << "[poc-reconnect] PHASE 2/2: restart the node service now "
            << "(waiting up to 180s for the re-handshake)" << std::endl;
  REQUIRE(WaitForCondition([&] { return c.connect_count.load() >= 2; }, 180s));
  REQUIRE(WaitForCondition([&] { return c.session_count.load() >= 2; }, 15s));
  REQUIRE(c.client->opened());
  std::cout << "[poc-reconnect] reconnected: connectCount="
            << c.connect_count.load() << " sessionCount=" << c.session_count.load()
            << std::endl;
  {
    std::lock_guard<std::mutex> lock(c.mutex);
    REQUIRE_FALSE(c.reconnect_plan.empty());
    std::cout << "[poc-reconnect] reconnect schedule entries="
              << c.reconnect_plan.size() << " first=("
              << c.reconnect_plan.front().first << ","
              << c.reconnect_plan.front().second << "ms)" << std::endl;
  }

  // The re-established session must work end-to-end (new ack round-trip).
  auto ping = std::make_shared<AckCapture>();
  c.board->emit("board:ping", sioxx::message::object(), ping->Callback());
  REQUIRE(ping->Wait(10s));
  REQUIRE(ping->Ok());
  std::cout << "[poc-reconnect] DONE: automatic reconnect + repeated handshake "
            << "verified" << std::endl;
}

#endif  // !defined(__EMSCRIPTEN__)
