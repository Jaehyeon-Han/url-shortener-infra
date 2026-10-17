// decideNextAction 순수 함수의 네 불변식을 증명하는 단위 테스트다.
// 실행: node --test modules/deploy-drainer/src/
//
// 설계 async-deploy-drainer.md 4절이 요구하는 불변식:
//   - 멱등성(idempotency): 같은 이벤트가 두 번 와도 상태 전이는 한 번만.
//   - 경쟁/리더 선출(race): 락 점유 중 enqueue는 NOOP로 흡수(핸들러 조건부 락은 index.test.mjs).
//   - 수렴(coalescing): 적체된 여러 목표 중 최신(desiredVersion)만 DEPLOY.
//   - dequeue: 배포 종료 이벤트로 깨어나 다음 목표가 있으면 RELEASE_THEN_DEPLOY.

import { test } from "node:test";
import assert from "node:assert/strict";
import { decideNextAction } from "./decide.mjs";

const NOW = 1_760_000_000;

// --- 멱등성 ---

test("멱등성: 중복 deployment-finished는 두 번째가 NOOP다", () => {
  // 첫 종료 이벤트: 추적 중인 배포가 끝나 락 해제 후 더 배포할 게 없으면 RELEASE.
  const first = decideNextAction({
    eventType: "deployment-finished",
    desiredVersion: "46",
    deployedVersion: "45",
    inFlightDeploymentId: "d-ABC",
    finishedDeploymentId: "d-ABC",
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(first.action, "RELEASE_THEN_DEPLOY");

  // 두 번째(중복) 종료 이벤트: 락은 이미 해제돼 inFlightDeploymentId가 없다 → NOOP.
  const second = decideNextAction({
    eventType: "deployment-finished",
    desiredVersion: "46",
    deployedVersion: "46",
    inFlightDeploymentId: undefined,
    finishedDeploymentId: "d-ABC",
    now: NOW,
    lockExpiresAt: undefined,
  });
  assert.equal(second.action, "NOOP");
});

test("멱등성: 엉뚱한 배포 ID의 종료 이벤트는 NOOP다(락 유지)", () => {
  const res = decideNextAction({
    eventType: "deployment-finished",
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-CURRENT",
    finishedDeploymentId: "d-OTHER", // 우리가 추적하는 배포가 아니다.
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(res.action, "NOOP");
});

// --- 경쟁/리더 선출(결정 레벨) ---

test("경쟁: 락 점유 중 enqueue는 NOOP다(슬롯 차 있음)", () => {
  const res = decideNextAction({
    eventType: "enqueue",
    desiredVersion: "48",
    deployedVersion: "45",
    inFlightDeploymentId: "d-INFLIGHT",
    finishedDeploymentId: undefined,
    now: NOW,
    lockExpiresAt: NOW + 1000, // 아직 유효한 락.
  });
  assert.equal(res.action, "NOOP");
});

test("경쟁: 좀비 락(TTL 만료) 중 enqueue는 탈취 후 배포(RELEASE_THEN_DEPLOY)", () => {
  const res = decideNextAction({
    eventType: "enqueue",
    desiredVersion: "48",
    deployedVersion: "45",
    inFlightDeploymentId: "d-ZOMBIE",
    finishedDeploymentId: undefined,
    now: NOW,
    lockExpiresAt: NOW - 1, // 만료된 락.
  });
  assert.equal(res.action, "RELEASE_THEN_DEPLOY");
  assert.equal(res.version, "48");
});

// --- 수렴(coalescing) ---

test("수렴: 슬롯 비고 desired>deployed면 최신 desiredVersion을 DEPLOY한다", () => {
  // 중간 버전(46, 47)이 enqueue에서 덮어써져 desiredVersion=49만 남은 상태.
  const res = decideNextAction({
    eventType: "enqueue",
    desiredVersion: "49",
    deployedVersion: "45",
    inFlightDeploymentId: undefined,
    finishedDeploymentId: undefined,
    now: NOW,
    lockExpiresAt: undefined,
  });
  assert.equal(res.action, "DEPLOY");
  assert.equal(res.version, "49"); // 최신만 배포.
});

test("수렴: desired<=deployed면 NOOP다(이미 최신 배포됨)", () => {
  const res = decideNextAction({
    eventType: "enqueue",
    desiredVersion: "45",
    deployedVersion: "45",
    inFlightDeploymentId: undefined,
    finishedDeploymentId: undefined,
    now: NOW,
    lockExpiresAt: undefined,
  });
  assert.equal(res.action, "NOOP");
});

test("최초 배포: deployedVersion 없음 + desiredVersion 존재면 DEPLOY다", () => {
  const res = decideNextAction({
    eventType: "enqueue",
    desiredVersion: "1",
    deployedVersion: undefined,
    inFlightDeploymentId: undefined,
    finishedDeploymentId: undefined,
    now: NOW,
    lockExpiresAt: undefined,
  });
  assert.equal(res.action, "DEPLOY");
  assert.equal(res.version, "1");
});

// --- dequeue (SUCCESS) ---

test("dequeue: SUCCESS 종료 후 desired>deployed면 RELEASE_THEN_DEPLOY다", () => {
  const res = decideNextAction({
    eventType: "deployment-finished",
    state: "SUCCESS",
    desiredVersion: "50", // 배포 중에 새 머지가 쌓였다.
    deployedVersion: "48", // 방금 48이 끝났다(아래 설명 참고).
    inFlightDeploymentId: "d-DONE",
    finishedDeploymentId: "d-DONE",
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(res.action, "RELEASE_THEN_DEPLOY");
  assert.equal(res.version, "50");
});

test("dequeue: SUCCESS 종료 후 desired<=deployed면 RELEASE(락만 해제)", () => {
  const res = decideNextAction({
    eventType: "deployment-finished",
    state: "SUCCESS",
    desiredVersion: "48",
    deployedVersion: "48",
    inFlightDeploymentId: "d-DONE",
    finishedDeploymentId: "d-DONE",
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(res.action, "RELEASE");
  assert.notEqual(res.keepDeployedVersion, true); // 성공은 버전을 올린다.
});

// --- 롤백 정책(a 방식): FAILURE/STOP ---

test("FAILURE: 락만 해제하고 deployedVersion 유지(keepDeployedVersion), 자동 재배포 없음", () => {
  // desired>deployed라도 FAILURE면 RELEASE_THEN_DEPLOY가 아니라 RELEASE(버전 유지)여야 한다.
  const res = decideNextAction({
    eventType: "deployment-finished",
    state: "FAILURE",
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-FAIL",
    finishedDeploymentId: "d-FAIL",
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(res.action, "RELEASE");
  assert.equal(res.keepDeployedVersion, true);
  assert.equal(res.version, undefined); // 재배포 지시 없음.
});

test("STOP: FAILURE와 동일하게 락만 해제 + 버전 유지 + 재배포 없음", () => {
  const res = decideNextAction({
    eventType: "deployment-finished",
    state: "STOP",
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-STOP",
    finishedDeploymentId: "d-STOP",
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(res.action, "RELEASE");
  assert.equal(res.keepDeployedVersion, true);
});

test("FAILURE라도 배포 ID 불일치면 NOOP다(멱등, 락 유지)", () => {
  const res = decideNextAction({
    eventType: "deployment-finished",
    state: "FAILURE",
    desiredVersion: "50",
    deployedVersion: "45",
    inFlightDeploymentId: "d-CURRENT",
    finishedDeploymentId: "d-OTHER",
    now: NOW,
    lockExpiresAt: NOW + 1000,
  });
  assert.equal(res.action, "NOOP");
});

test("FAILURE 후 재개: 락 해제된 상태에서 다음 enqueue가 오면 DEPLOY로 재개된다", () => {
  // FAILURE 처리로 inFlightDeploymentId가 제거된 뒤의 상태를 시뮬레이션한다.
  // desiredVersion은 보존돼 있으므로(50), 새 enqueue가 오면 DEPLOY가 다시 트리거된다.
  const res = decideNextAction({
    eventType: "enqueue",
    desiredVersion: "50",
    deployedVersion: "45", // FAILURE라 올라가지 않았다.
    inFlightDeploymentId: undefined, // 락 해제됨.
    now: NOW,
    lockExpiresAt: undefined,
  });
  assert.equal(res.action, "DEPLOY");
  assert.equal(res.version, "50");
});

// --- 기타 방어 ---

test("알 수 없는 이벤트 타입은 NOOP다", () => {
  const res = decideNextAction({
    eventType: "something-else",
    desiredVersion: "9",
    deployedVersion: "1",
    now: NOW,
  });
  assert.equal(res.action, "NOOP");
});
