"""Unit tests for the redirect Lambda handler."""

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))


class RedirectHandlerTests(unittest.TestCase):
    def setUp(self):
        os.environ["DASHBOARD_BUCKET"] = "test-bucket"
        os.environ["PRESIGNED_TTL_SECONDS"] = "1800"

    def test_handler_returns_302_with_presigned_url(self):
        import handler

        s3_client = MagicMock()
        s3_client.generate_presigned_url.return_value = "https://example.com/signed"

        with patch("handler.boto3.client", return_value=s3_client):
            response = handler.lambda_handler({}, None)

        self.assertEqual(response["statusCode"], 302)
        self.assertEqual(response["headers"]["Location"], "https://example.com/signed")
        s3_client.generate_presigned_url.assert_called_once_with(
            "get_object",
            Params={"Bucket": "test-bucket", "Key": "dashboard.html"},
            ExpiresIn=1800,
        )


if __name__ == "__main__":
    unittest.main()
