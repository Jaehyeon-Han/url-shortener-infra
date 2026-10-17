// 드레이너의 의사결정 코어 — 순수 함수(부작용 없음).
//
// AWS 호출과 분리해 단위 테스트로 불변식을 증명한다. (이 리포의 rebuildCounters가
// "부작용 없는 순수 재구성 함수를 테스트로 정합성 증명"하는 것과 동일한 철학이다.)
// 설계 문서 async-deploy-drainer.md 4절의 시그니처/규칙을 그대로 구현한다.
//
// DeployQueue 한 행이 "큐(desiredVersion) + 분산 락(inFlightDeploymentId) +
// 멱등 저장소" 세 역할을 동시에 한다. 이 함수는 그 행의 현재 상태와 들어온 이벤트를
// 받아 "다음에 무엇을 할지"만 결정한다. 실제 조건부 락 획득/배포는 핸들러(index.mjs)가 한다.

// Lambda 버전은 "47" 같은 숫자 문자열이다. undefined/null은 "아직 없음"으로 보고
// -1(어떤 실제 버전보다도 작음)로 환산해 비교한다. 그래야 최초 배포(deployedVersion 없음)에서
// desiredVersion > deployedVersion이 성립한다.
function toNum(version) {
  if (version === undefined || version === null || version === "") {
    return -1;
  }
  const n = Number(version);
  return Number.isNaN(n) ? -1 : n;
}

// 락이 유효하게 점유 중인지 판정한다. inFlightDeploymentId가 있고, TTL(lockExpiresAt)이
// 아직 만료되지 않았으면 점유 중이다. lockExpiresAt < now면 좀비 락으로 간주해 점유로 보지 않는다.
// (EventBridge 이벤트 유실·드레이너 중도 사망 대비 안전망. 설계 3·10절.)
function isLockHeld({ inFlightDeploymentId, lockExpiresAt, now }) {
  if (!inFlightDeploymentId) {
    return false;
  }
  // lockExpiresAt이 없으면(과거 데이터 등) 보수적으로 점유 중으로 본다.
  if (lockExpiresAt === undefined || lockExpiresAt === null) {
    return true;
  }
  return Number(lockExpiresAt) >= now;
}

// decideNextAction: 이벤트와 현재 상태로 다음 행동을 결정하는 순수 함수.
//
// 입력:
//   eventType             "enqueue" | "deployment-finished"
//   desiredVersion        string | undefined  — 큐(배포돼야 할 최신 버전)
//   deployedVersion       string | undefined  — 마지막 성공 배포 버전
//   inFlightDeploymentId  string | undefined  — 락(진행 중 배포 ID)
//   finishedDeploymentId  string | undefined  — deployment-finished 이벤트의 배포 ID
//   state                 string | undefined  — deployment-finished의 상태 "SUCCESS"|"FAILURE"|"STOP"
//   now                   number              — 현재 epoch 초
//   lockExpiresAt         number | undefined  — 락 TTL(epoch 초)
//
// 출력: { action, version? }
//   "DEPLOY"               슬롯이 비어 즉시 배포 시작(version=desiredVersion)
//   "RELEASE_THEN_DEPLOY"  락 해제 후 이어서 다음 배포(version=desiredVersion)
//   "RELEASE"              락만 해제한다. keepDeployedVersion=true면 deployedVersion을 올리지 않는다.
//   "NOOP"                 아무것도 안 함
//
// 롤백 정책(a 방식): deployment-finished의 state가 성공이 아니면(FAILURE/STOP) 락만 해제하고
//   deployedVersion은 올리지 않으며(실패 버전을 성공으로 기록하지 않음) 자동 재배포도 하지 않는다
//   (dequeue 재개 금지). desiredVersion은 보존되므로, 이후 새 push(enqueue)가 오면 그때 재개된다.
//   STOP은 FAILURE와 동일 취급한다(사람 개입이든 알람이든 "성공 아님"이므로 안전 동작은 같다).
export function decideNextAction({
  eventType,
  desiredVersion,
  deployedVersion,
  inFlightDeploymentId,
  finishedDeploymentId,
  state,
  now,
  lockExpiresAt,
}) {
  const desired = toNum(desiredVersion);
  const deployed = toNum(deployedVersion);
  const lockHeld = isLockHeld({ inFlightDeploymentId, lockExpiresAt, now });

  if (eventType === "deployment-finished") {
    // 규칙 2: finishedDeploymentId가 inFlightDeploymentId와 "일치할 때만" 락을 해제한다.
    // 엉뚱한(또는 중복으로 재전달된) 배포 종료 이벤트는 무시한다 → 멱등.
    if (!inFlightDeploymentId || finishedDeploymentId !== inFlightDeploymentId) {
      return { action: "NOOP" };
    }

    // 롤백/중지(FAILURE/STOP): 성공이 아니므로 deployedVersion을 올리지 않고 자동 재배포도 안 한다.
    // 락만 해제한다. desiredVersion은 그대로 남아, 다음 enqueue가 오면 그때 배포가 재개된다.
    if (state === "FAILURE" || state === "STOP") {
      return { action: "RELEASE", keepDeployedVersion: true };
    }

    // 성공(SUCCESS 또는 명시되지 않은 종료 이벤트의 보수적 기본): 방금 끝난 배포가 우리가 추적하던
    // 그 배포다. 락을 해제하고 deployedVersion을 갱신한다. 큐에 더 새 목표가 있으면(desired > deployed)
    // 이어서 다음 배포를 수행하고, 아니면 락만 해제한다.
    if (desired > deployed) {
      return { action: "RELEASE_THEN_DEPLOY", version: String(desiredVersion) };
    }
    return { action: "RELEASE" };
  }

  if (eventType === "enqueue") {
    // 규칙 1: 락이 유효하게 점유 중이면(= 배포 진행 중) 아무것도 안 한다.
    // desiredVersion 갱신은 enqueue 쓰기(DDB)에서 이미 반영됐으므로 여기선 NOOP.
    if (lockHeld) {
      return { action: "NOOP" };
    }
    // 락이 없거나(슬롯 빔) 좀비 락(TTL 만료)이다.
    // 배포할 더 새 목표가 있으면 배포한다. 좀비 락이면 핸들러가 조건부로 탈취 후 배포한다.
    if (desired > deployed) {
      if (inFlightDeploymentId) {
        // 좀비 락 탈취 경로: 락을 해제(탈취)하고 이어서 배포한다.
        return { action: "RELEASE_THEN_DEPLOY", version: String(desiredVersion) };
      }
      return { action: "DEPLOY", version: String(desiredVersion) };
    }
    // desired <= deployed: 이미 최신이 배포됨(NOOP).
    return { action: "NOOP" };
  }

  // 알 수 없는 이벤트 타입은 무시한다.
  return { action: "NOOP" };
}
