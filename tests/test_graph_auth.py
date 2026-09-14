import unittest
from unittest.mock import MagicMock, call, patch

import ingest_sharepoint_to_search


class InteractiveGraphTokenTests(unittest.TestCase):
    @patch("ingest_sharepoint_to_search.msal.PublicClientApplication")
    def test_device_flow_returns_graph_token(self, mock_application):
        app = MagicMock()
        app.get_accounts.return_value = []
        app.initiate_device_flow.return_value = {
            "user_code": "TEST-CODE",
            "message": "Complete device sign-in",
        }
        app.acquire_token_by_device_flow.return_value = {"access_token": "graph-token"}
        mock_application.return_value = app

        token = ingest_sharepoint_to_search.get_interactive_graph_token(
            "tenant",
            "client",
            scopes=["Files.Read.All"],
        )

        self.assertEqual(token, "graph-token")
        mock_application.assert_called_once_with(
            client_id="client",
            authority="https://login.microsoftonline.com/tenant",
        )
        app.initiate_device_flow.assert_called_once_with(
            scopes=["Files.Read.All"]
        )


class GraphDownloadTests(unittest.TestCase):
    @patch("ingest_sharepoint_to_search.request")
    def test_download_url_does_not_receive_graph_bearer_token(self, mock_request):
        source = ingest_sharepoint_to_search.SourceFile(
            item_id="item",
            name="document.pdf",
            web_url="https://example.sharepoint.com/document.pdf",
            size=10,
            last_modified=None,
            mime_type="application/pdf",
        )
        mock_request.side_effect = [
            {"@microsoft.graph.downloadUrl": "https://example.sharepoint.com/download"},
            (b"content", {}),
        ]

        content = ingest_sharepoint_to_search.download_graph_file("drive", source, "token")

        self.assertEqual(content, b"content")
        self.assertEqual(
            mock_request.call_args_list[-1],
            call(
                "GET",
                "https://example.sharepoint.com/download",
                expect_json=False,
                timeout=600,
            ),
        )


class DocumentIntelligenceCredentialTests(unittest.TestCase):
    @patch("ingest_sharepoint_to_search.get_cli_token", return_value="aad-token")
    @patch("ingest_sharepoint_to_search.run_az", return_value="true")
    def test_disabled_local_auth_uses_entra(self, mock_run_az, mock_get_cli_token):
        credential = ingest_sharepoint_to_search.get_document_intelligence_credential(
            "resource-group", "document-intelligence"
        )

        self.assertEqual(credential, "aad:aad-token")
        self.assertEqual(mock_run_az.call_count, 1)
        mock_get_cli_token.assert_called_once_with("https://cognitiveservices.azure.com")

    @patch("ingest_sharepoint_to_search.get_cli_token")
    @patch("ingest_sharepoint_to_search.run_az", side_effect=["false", "account-key"])
    def test_enabled_local_auth_uses_key(self, mock_run_az, mock_get_cli_token):
        credential = ingest_sharepoint_to_search.get_document_intelligence_credential(
            "resource-group", "document-intelligence"
        )

        self.assertEqual(credential, "key:account-key")
        self.assertEqual(mock_run_az.call_count, 2)
        mock_get_cli_token.assert_not_called()


if __name__ == "__main__":
    unittest.main()