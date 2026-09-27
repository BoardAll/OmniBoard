"""转换任务：创建/列表/详情/产物下载/幂等删除（假引擎）。"""

from __future__ import annotations

from conftest import PNG_MAGIC, FakeDoc

PDF_BYTES = b"%PDF-1.4 fake-payload"
UPLOAD = {"file": ("doc.pdf", PDF_BYTES, "application/pdf")}


def _create_job(client, operation: str, **extra):
    data = {"operation": operation, **extra}
    return client.post("/v1/convert/jobs", files=UPLOAD, data=data)


def test_text_job_lifecycle(make_client, fake_engine):
    fake_engine(doc=FakeDoc(texts=["alpha", "beta"]))
    client = make_client()

    resp = _create_job(client, "text")
    assert resp.status_code == 201
    job = resp.json()["data"]
    assert job["id"].startswith("job_")
    assert job["operation"] == "text"
    assert job["status"] == "succeeded"
    assert job["result"]["pageCount"] == 2
    assert job["result"]["text"] == "alpha\nbeta"
    assert job["result"]["charCount"] == len("alpha\nbeta")
    assert job["error"] is None
    assert job["payloadMediaType"] == "text/plain"
    assert "payload" not in job  # 内部产物字段不外泄

    # 详情
    detail = client.get(f"/v1/convert/jobs/{job['id']}").json()["data"]
    assert detail["id"] == job["id"]

    # 列表
    listing = client.get("/v1/convert/jobs").json()["data"]
    assert listing["total"] == 1
    assert listing["jobs"][0]["id"] == job["id"]

    # 产物下载
    result = client.get(f"/v1/convert/jobs/{job['id']}/result")
    assert result.status_code == 200
    assert result.headers["content-type"].startswith("text/plain")
    assert result.text == "alpha\nbeta"

    # 幂等删除
    deleted = client.delete(f"/v1/convert/jobs/{job['id']}").json()["data"]
    assert deleted == {"jobId": job["id"], "deleted": True, "alreadyDeleted": False}
    again = client.delete(f"/v1/convert/jobs/{job['id']}").json()["data"]
    assert again == {"jobId": job["id"], "deleted": False, "alreadyDeleted": True}
    assert client.get(f"/v1/convert/jobs/{job['id']}").status_code == 404


def test_png_job_lifecycle(make_client, fake_engine):
    fake_engine(doc=FakeDoc(page_count=2))
    client = make_client()

    job = _create_job(client, "png", page="1", dpi="96").json()["data"]
    assert job["status"] == "succeeded"
    assert job["page"] == 1 and job["dpi"] == 96
    assert job["result"] == {"page": 1, "dpi": 96, "sizeBytes": job["result"]["sizeBytes"]}
    assert job["result"]["sizeBytes"] > 0
    assert job["payloadMediaType"] == "image/png"

    result = client.get(f"/v1/convert/jobs/{job['id']}/result")
    assert result.status_code == 200
    assert result.headers["content-type"].startswith("image/png")
    assert result.content.startswith(PNG_MAGIC)


def test_info_job_has_no_downloadable_payload(make_client, fake_engine):
    fake_engine(doc=FakeDoc(page_count=2))
    client = make_client()
    job = _create_job(client, "info").json()["data"]
    assert job["status"] == "succeeded"
    assert job["result"]["pageCount"] == 2
    assert job["payloadMediaType"] is None
    resp = client.get(f"/v1/convert/jobs/{job['id']}/result")
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "Conflict"


def test_failed_job_records_error(make_client, fake_engine):
    fake_engine(open_error=RuntimeError("broken"))
    client = make_client()
    resp = _create_job(client, "text")
    assert resp.status_code == 201  # 任务语义：转换失败落任务记录
    job = resp.json()["data"]
    assert job["status"] == "failed"
    assert job["result"] is None
    assert job["error"]["code"] == "InvalidArgument"
    assert "invalid pdf (RuntimeError)" in job["error"]["message"]
    assert client.get(f"/v1/convert/jobs/{job['id']}/result").status_code == 409


def test_unknown_operation_400(make_client, fake_engine):
    fake_engine()
    client = make_client()
    resp = _create_job(client, "docx")
    assert resp.status_code == 400
    error = resp.json()["error"]
    assert error["code"] == "InvalidArgument"
    assert "docx" in error["message"]
    assert client.get("/v1/convert/jobs").json()["data"]["total"] == 0


def test_png_job_dpi_out_of_range_400(make_client, fake_engine):
    fake_engine()
    client = make_client()
    resp = _create_job(client, "png", dpi="5000")
    assert resp.status_code == 400
    assert "dpi out of range" in resp.json()["error"]["message"]


def test_job_not_found_404(make_client, fake_engine):
    fake_engine()
    client = make_client()
    assert client.get("/v1/convert/jobs/job_missing").status_code == 404
    assert client.get("/v1/convert/jobs/job_missing/result").status_code == 404
    assert client.delete("/v1/convert/jobs/job_missing").json()["data"] == {
        "jobId": "job_missing",
        "deleted": False,
        "alreadyDeleted": True,
    }


def test_job_store_eviction():
    from src.app import JobStore

    store = JobStore(max_jobs=2)
    first = store.add(operation="info", status="succeeded")
    second = store.add(operation="info", status="succeeded")
    third = store.add(operation="info", status="succeeded")
    assert store.count() == 2
    assert store.get(first["id"]) is None  # FIFO 驱逐最旧任务
    assert store.get(second["id"]) is not None
    assert store.get(third["id"]) is not None
