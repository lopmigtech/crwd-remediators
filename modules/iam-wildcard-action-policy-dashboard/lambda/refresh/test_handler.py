"""Unit tests for the refresh Lambda handler — uses mocked boto3 clients."""

import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))


class RefreshHandlerTests(unittest.TestCase):
    def setUp(self):
        os.environ["CONFIG_RULE_NAME"] = "test-rule"
        os.environ["DASHBOARD_BUCKET"] = "test-bucket"
        os.environ["EXCLUDED_RESOURCE_IDS"] = ""

    def test_handler_renders_html_and_uploads_to_s3(self):
        import handler

        sts_client = MagicMock()
        sts_client.get_caller_identity.return_value = {"Account": "111111111111"}

        config_paginator = MagicMock()
        config_paginator.paginate.return_value = iter([{"EvaluationResults": []}])
        config_client = MagicMock()
        config_client.get_paginator.return_value = config_paginator

        iam_paginator = MagicMock()
        iam_paginator.paginate.return_value = iter([{"Policies": []}])
        iam_client = MagicMock()
        iam_client.get_paginator.return_value = iam_paginator

        s3_client = MagicMock()

        sess = MagicMock()
        sess.region_name = "us-east-1"
        sess.client.side_effect = lambda name, **kwargs: {
            "config": config_client, "iam": iam_client, "sts": sts_client, "s3": s3_client,
        }[name]

        with patch("handler.boto3.session.Session", return_value=sess):
            result = handler.lambda_handler({}, None)

        self.assertEqual(result["status"], "ok")
        s3_client.put_object.assert_called_once()
        kwargs = s3_client.put_object.call_args.kwargs
        self.assertEqual(kwargs["Bucket"], "test-bucket")
        self.assertEqual(kwargs["Key"], "dashboard.html")
        self.assertIn(b"<!DOCTYPE html>", kwargs["Body"])
        self.assertEqual(kwargs["ContentType"], "text/html; charset=utf-8")
        self.assertEqual(kwargs["ServerSideEncryption"], "AES256")


if __name__ == "__main__":
    unittest.main()
