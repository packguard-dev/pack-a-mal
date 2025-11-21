# Pack-a-mal REST API Documentation

## Table of Contents
1. [Overview](#overview)
2. [System Information](#system-information)
3. [Authentication](#authentication)
4. [API Endpoints](#api-endpoints)
5. [Data Models](#data-models)
6. [Error Handling](#error-handling)
7. [Rate Limiting](#rate-limiting)
8. [Examples](#examples)

---

## Overview

The Pack-a-mal REST API provides programmatic access to package analysis services. The API allows you to submit packages for security analysis, check analysis status, and retrieve results. All API endpoints use JSON for request and response payloads.

**Base URL**: `https://packguard.dev` (production) or `http://localhost:8000` (development)

**API Version**: v1

**Content-Type**: `application/json`

---

## System Information

### Operating System
- **OS**: Linux (5.15.0-161-generic)
- **Server**: Gunicorn 23.0.0

### Technology Stack

#### Core Framework
- **Django**: 5.1.6
- **Python**: 3.x
- **Database**: PostgreSQL

#### Key Libraries
- **Django**: Web framework
- **Gunicorn**: WSGI HTTP server
- **PostgreSQL**: Database backend
- **requests**: HTTP client library (2.32.3)
- **GitPython**: Git repository handling (3.1.44)
- **beautifulsoup4**: HTML parsing (4.13.3)
- **lxml**: XML/HTML processing (5.4.0)
- **numpy**: Numerical computing (2.2.5)
- **RapidFuzz**: String matching (3.13.0)
- **Levenshtein**: String distance calculation (0.27.1)
- **django_distill**: Static site generation

#### Additional Dependencies
- **httpx**: Async HTTP client (0.28.1)
- **PyYAML**: YAML parsing (6.0.2)
- **validators**: Data validation (0.34.0)
- **yara-python**: Pattern matching

---

## Authentication

### API Key Authentication

All protected API endpoints require authentication using an API key. API keys are managed through the Django admin interface.

### Authentication Methods

The API supports two methods for providing your API key:

#### Method 1: Bearer Token (Recommended)
```http
Authorization: Bearer YOUR_API_KEY
```

#### Method 2: Custom Header
```http
X-API-Key: YOUR_API_KEY
```

### API Key Model

API keys are stored in the `APIKey` model with the following properties:

- **name**: Human-readable name for the API key
- **key**: 64-character alphanumeric API key (auto-generated)
- **is_active**: Boolean flag to enable/disable the key
- **rate_limit_per_hour**: Maximum requests per hour (default: 100)
- **created_at**: Timestamp when the key was created
- **last_used**: Timestamp of last API usage

### Generating API Keys

API keys are automatically generated when creating a new `APIKey` instance through the Django admin. The key is a secure random 64-character string using ASCII letters and digits.

### Authentication Code

The authentication is implemented in `package_analysis/auth.py`:

```python
def require_api_key(view_func):
    """
    Decorator to require valid API key for API endpoints
    """
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        # Get API key from Authorization header or X-API-Key header
        api_key = None
        
        # Try Authorization header first (Bearer token format)
        auth_header = request.META.get('HTTP_AUTHORIZATION', '')
        if auth_header.startswith('Bearer '):
            api_key = auth_header[7:]
        else:
            # Try X-API-Key header
            api_key = request.META.get('HTTP_X_API_KEY')
        
        if not api_key:
            return JsonResponse({
                'error': 'API key required',
                'message': 'Please provide API key in Authorization header (Bearer <key>) or X-API-Key header'
            }, status=401)
        
        # Validate API key
        try:
            api_key_obj = APIKey.objects.get(key=api_key, is_active=True)
        except APIKey.DoesNotExist:
            return JsonResponse({
                'error': 'Invalid API key',
                'message': 'The provided API key is invalid or inactive'
            }, status=401)
        
        # Check rate limiting
        rate_limit_exceeded = check_rate_limit(api_key_obj)
        if rate_limit_exceeded:
            return JsonResponse({
                'error': 'Rate limit exceeded',
                'message': f'Maximum {api_key_obj.rate_limit_per_hour} requests per hour exceeded'
            }, status=429)
        
        # Update last used timestamp
        api_key_obj.last_used = timezone.now()
        api_key_obj.save(update_fields=['last_used'])
        
        # Add API key object to request for use in view
        request.api_key = api_key_obj
        
        return view_func(request, *args, **kwargs)
    
    return wrapper
```

### Rate Limiting

Rate limiting is implemented using Django's cache framework. Each API key has a configurable `rate_limit_per_hour` (default: 100 requests/hour). When the limit is exceeded, the API returns a `429 Too Many Requests` response.

---

## API Endpoints

### Base Path
All API endpoints are prefixed with `/api/v1/`

---

### 1. Analyze Package

Submit a package for analysis using a Package URL (PURL).

**Endpoint**: `POST /api/v1/analyze/`

**Authentication**: Required

**Request Headers**:
```http
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
X-Idempotency-Key: optional-unique-key  # Optional, for idempotent requests
```

**Request Body**:
```json
{
  "purl": "pkg:pypi/requests@2.28.1",
  "priority": 0  // Optional, defaults to 0. Higher numbers = higher priority
}
```

**PURL Format**:
The API supports Package URLs (PURL) as defined in the purl-spec. Supported ecosystems:
- `pkg:pypi/<package>@<version>` - Python packages
- `pkg:npm/<package>@<version>` - Node.js packages
- `pkg:gem/<package>@<version>` - Ruby gems
- `pkg:maven/<group>:<artifact>@<version>` - Maven packages
- `pkg:packagist/<package>@<version>` - PHP Composer packages

**Response (202 Accepted - New Task Queued)**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "status": "queued",
    "queue_position": 3,
    "status_url": "https://packguard.dev/api/v1/task/123/",
    "result_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "message": "Analysis queued at position 3"
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440000"
}
```

**Response (200 OK - Cached Result)**:
```json
{
  "task_id": 120,
  "status": "completed",
  "result_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
  "report_metadata": {
    "filename": "2.28.1.json",
    "size_bytes": 15420,
    "created_at": "2024-01-15T10:20:00Z",
    "download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "folder_structure": "reports/pypi/requests/"
  },
  "message": "Analysis already exists (cached result)"
}
```

**Response (200 OK - Active Task)**:
```json
{
  "success": true,
  "data": {
    "task_id": 121,
    "status": "running",
    "status_url": "https://packguard.dev/api/v1/task/121/",
    "result_url": "https://packguard.dev/media/reports/pypi/numpy/1.24.0.json",
    "message": "Analysis already running"
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440001"
}
```

**Error Responses**:
- `400 Bad Request`: Invalid PURL format or missing required fields
- `401 Unauthorized`: Missing or invalid API key
- `429 Too Many Requests`: Rate limit exceeded
- `500 Internal Server Error`: Server error

---

### 2. Get Task Status

Check the status of an analysis task.

**Endpoint**: `GET /api/v1/task/<task_id>/`

**Authentication**: Not required (public endpoint)

**Request Headers**:
```http
Content-Type: application/json
```

**Response (200 OK - Queued Task)**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "purl": "pkg:pypi/requests@2.28.1",
    "status": "queued",
    "created_at": "2024-01-15T10:30:00Z",
    "expected_download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "package_name": "requests",
    "package_version": "2.28.1",
    "ecosystem": "pypi",
    "priority": 0,
    "queue_position": 3,
    "queued_at": "2024-01-15T10:30:00Z",
    "timeout_minutes": 30,
    "container_id": null,
    "last_heartbeat": null
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440002"
}
```

**Response (200 OK - Running Task)**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "purl": "pkg:pypi/requests@2.28.1",
    "status": "running",
    "created_at": "2024-01-15T10:30:00Z",
    "started_at": "2024-01-15T10:35:00Z",
    "expected_download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "package_name": "requests",
    "package_version": "2.28.1",
    "ecosystem": "pypi",
    "priority": 0,
    "queue_position": null,
    "timeout_minutes": 30,
    "container_id": "abc123def456",
    "last_heartbeat": "2024-01-15T10:40:00Z",
    "remaining_time_minutes": 25,
    "is_timed_out": false
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440003"
}
```

**Response (200 OK - Completed Task)**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "purl": "pkg:pypi/requests@2.28.1",
    "status": "completed",
    "created_at": "2024-01-15T10:30:00Z",
    "started_at": "2024-01-15T10:35:00Z",
    "completed_at": "2024-01-15T10:50:00Z",
    "expected_download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "package_name": "requests",
    "package_version": "2.28.1",
    "ecosystem": "pypi",
    "priority": 0,
    "result_url": "https://packguard.dev/get_report/456/",
    "download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "report_metadata": {
      "filename": "2.28.1.json",
      "size_bytes": 15420,
      "created_at": "2024-01-15T10:50:00Z",
      "download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
      "folder_structure": "reports/pypi/requests/"
    }
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440004"
}
```

**Response (200 OK - Failed Task)**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "purl": "pkg:pypi/requests@2.28.1",
    "status": "failed",
    "created_at": "2024-01-15T10:30:00Z",
    "started_at": "2024-01-15T10:35:00Z",
    "completed_at": "2024-01-15T10:40:00Z",
    "error_message": "Task timed out after 30 minutes",
    "error_category": "timeout_error",
    "error_details": {
      "timeout_minutes": 30,
      "started_at": "2024-01-15T10:35:00Z",
      "timed_out_at": "2024-01-15T11:05:00Z",
      "container_id": "abc123def456",
      "container_stopped": true
    }
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440005"
}
```

**Error Responses**:
- `404 Not Found`: Task not found

---

### 3. List Tasks

Get a paginated list of analysis tasks for your API key.

**Endpoint**: `GET /api/v1/reports/`

**Authentication**: Required

**Query Parameters**:
- `page` (optional): Page number (default: 1)
- `page_size` (optional): Items per page (default: 20, max: 100)
- `status` (optional): Filter by status (`pending`, `queued`, `running`, `completed`, `failed`)

**Request Headers**:
```http
Authorization: Bearer YOUR_API_KEY
```

**Response (200 OK)**:
```json
{
  "success": true,
  "data": {
    "items": [
      {
        "task_id": 123,
        "purl": "pkg:pypi/requests@2.28.1",
        "status": "completed",
        "created_at": "2024-01-15T10:30:00Z",
        "package_name": "requests",
        "package_version": "2.28.1",
        "ecosystem": "pypi",
        "priority": 0,
        "queue_position": null,
        "queued_at": null,
        "result_url": "https://packguard.dev/get_report/456/",
        "download_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
        "error_message": null,
        "error_category": null
      }
    ],
    "page": 1,
    "page_size": 20,
    "total": 45
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440006"
}
```

**Error Responses**:
- `400 Bad Request`: Invalid pagination parameters
- `401 Unauthorized`: Missing or invalid API key

---

### 4. Queue Status

Get the current status of the analysis queue (all tasks across all API keys).

**Endpoint**: `GET /api/v1/queue/status/`

**Authentication**: Not required (public endpoint)

**Response (200 OK)**:
```json
{
  "success": true,
  "data": {
    "queue_length": 5,
    "running_tasks": [
      {
        "task_id": 120,
        "purl": "pkg:pypi/numpy@1.24.0",
        "started_at": "2024-01-15T10:25:00Z",
        "created_at": "2024-01-15T10:25:00Z"
      }
    ],
    "queued_tasks": [
      {
        "task_id": 121,
        "purl": "pkg:pypi/pandas@2.0.0",
        "queue_position": 1,
        "priority": 0,
        "queued_at": "2024-01-15T10:26:00Z",
        "created_at": "2024-01-15T10:26:00Z"
      },
      {
        "task_id": 122,
        "purl": "pkg:npm/lodash@4.17.21",
        "queue_position": 2,
        "priority": 0,
        "queued_at": "2024-01-15T10:27:00Z",
        "created_at": "2024-01-15T10:27:00Z"
      }
    ]
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440007"
}
```

---

### 5. Task Queue Position

Get the queue position of a specific task.

**Endpoint**: `GET /api/v1/task/<task_id>/queue/`

**Authentication**: Required

**Request Headers**:
```http
Authorization: Bearer YOUR_API_KEY
```

**Response (200 OK)**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "status": "queued",
    "queue_position": 3,
    "purl": "pkg:pypi/requests@2.28.1",
    "package_name": "requests",
    "package_version": "2.28.1",
    "ecosystem": "pypi"
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440008"
}
```

**Error Responses**:
- `404 Not Found`: Task not found or access denied
- `401 Unauthorized`: Missing or invalid API key

---

### 6. Timeout Status

Get status of running tasks and their timeout information.

**Endpoint**: `GET /api/v1/timeout/status/`

**Authentication**: Not required (public endpoint)

**Response (200 OK)**:
```json
{
  "success": true,
  "data": {
    "running_tasks": 1,
    "timed_out_tasks": 0,
    "tasks": [
      {
        "task_id": 123,
        "purl": "pkg:pypi/requests@2.28.1",
        "started_at": "2024-01-15T10:30:00Z",
        "timeout_minutes": 30,
        "remaining_minutes": 25,
        "is_timed_out": false,
        "container_id": "abc123def456",
        "container_running": true
      }
    ]
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440009"
}
```

---

### 7. Check Timeouts

Manually trigger timeout check and cleanup.

**Endpoint**: `POST /api/v1/timeout/check/`

**Authentication**: Not required (public endpoint)

**Response (200 OK)**:
```json
{
  "success": true,
  "data": {
    "message": "Timeout check completed",
    "status": {
      "running_tasks": 0,
      "timed_out_tasks": 1,
      "tasks": []
    }
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440010"
}
```

---

## Data Models

### AnalysisTask

Represents an analysis task in the system.

**Fields**:
- `id` (integer): Unique task identifier
- `api_key` (ForeignKey): API key that created the task
- `purl` (string, max 500): Package URL submitted for analysis
- `package_name` (string, max 200): Extracted package name
- `package_version` (string, max 100): Extracted package version
- `ecosystem` (string, max 50): Package ecosystem (pypi, npm, gem, maven, packagist)
- `status` (string): Task status (`pending`, `queued`, `running`, `completed`, `failed`)
- `created_at` (datetime): When the task was created
- `started_at` (datetime, nullable): When the task started processing
- `completed_at` (datetime, nullable): When the task completed
- `error_message` (text, nullable): Error message if task failed
- `error_category` (string, nullable): Error category (e.g., `timeout_error`, `docker_error`, `analysis_error`)
- `error_details` (JSON, nullable): Detailed error information
- `report` (OneToOne, nullable): Link to the analysis report
- `download_url` (URL, nullable): URL to download the JSON report file
- `idempotency_key` (string, max 64, nullable): Idempotency key for duplicate prevention
- `queue_position` (integer, nullable): Position in the analysis queue
- `priority` (integer): Priority level (default: 0, higher = higher priority)
- `queued_at` (datetime, nullable): When the task was added to queue
- `timeout_minutes` (integer): Timeout duration in minutes (default: 30)
- `container_id` (string, max 100, nullable): Docker container ID if running
- `last_heartbeat` (datetime, nullable): Last heartbeat timestamp from running container

**Indexes**:
- `purl`
- `status`, `created_at`
- `api_key`, `created_at`
- `status`, `queue_position`
- `priority`, `queued_at`
- `status`, `started_at`
- `container_id`
- Unique constraint on `api_key`, `idempotency_key` (when idempotency_key is not null)

### APIKey

Represents an API key for authentication.

**Fields**:
- `id` (integer): Unique identifier
- `name` (string, max 100): Human-readable name
- `key` (string, max 64, unique): The API key (64-character alphanumeric)
- `created_at` (datetime): When the key was created
- `is_active` (boolean): Whether the key is active
- `rate_limit_per_hour` (integer): Maximum requests per hour (default: 100)
- `last_used` (datetime, nullable): Last time the key was used

### ReportDynamicAnalysis

Represents an analysis report.

**Fields**:
- `id` (integer): Unique identifier
- `package` (OneToOne): Link to the Package model
- `time` (float): Analysis duration in seconds
- `report` (JSON): The analysis report data

### Package

Represents a package.

**Fields**:
- `id` (integer): Unique identifier
- `package_name` (string, max 20): Package name
- `package_version` (string, max 20): Package version
- `ecosystem` (string, max 20): Package ecosystem

---

## Error Handling

### Standard Error Response Format

All error responses follow this format:

```json
{
  "success": false,
  "error": "Error type",
  "message": "Human-readable error message",
  "code": "ERROR_CODE",  // Optional
  "fields": {  // Optional, for validation errors
    "field_name": ["Error message"]
  },
  "request_id": "550e8400-e29b-41d4-a716-446655440000"
}
```

### HTTP Status Codes

- `200 OK`: Request successful
- `202 Accepted`: Request accepted and queued
- `400 Bad Request`: Invalid request parameters
- `401 Unauthorized`: Authentication required or invalid
- `404 Not Found`: Resource not found
- `405 Method Not Allowed`: HTTP method not allowed
- `429 Too Many Requests`: Rate limit exceeded
- `500 Internal Server Error`: Server error

### Common Error Types

1. **API key required** (401)
   ```json
   {
     "success": false,
     "error": "API key required",
     "message": "Please provide API key in Authorization header (Bearer <key>) or X-API-Key header"
   }
   ```

2. **Invalid API key** (401)
   ```json
   {
     "success": false,
     "error": "Invalid API key",
     "message": "The provided API key is invalid or inactive"
   }
   ```

3. **Rate limit exceeded** (429)
   ```json
   {
     "success": false,
     "error": "Rate limit exceeded",
     "message": "Maximum 100 requests per hour exceeded"
   }
   ```

4. **Invalid PURL format** (400)
   ```json
   {
     "success": false,
     "error": "Invalid PURL format",
     "message": "PURL must be a valid package URL starting with pkg:"
   }
   ```

5. **Task not found** (404)
   ```json
   {
     "success": false,
     "error": "Task not found",
     "message": "Analysis task not found or access denied"
   }
   ```

---

## Rate Limiting

### Rate Limit Implementation

Rate limiting is implemented using Django's cache framework. Each API key has a configurable `rate_limit_per_hour` (default: 100 requests/hour).

### Rate Limit Headers

When rate limiting is active, the API may include these headers:
- `X-RateLimit-Limit`: Maximum requests per hour
- `X-RateLimit-Remaining`: Remaining requests in current window
- `X-RateLimit-Reset`: Timestamp when the rate limit resets

### Rate Limit Exceeded Response

When the rate limit is exceeded, the API returns:
- **Status Code**: `429 Too Many Requests`
- **Response**: Standard error format with rate limit message

---

## Examples

### Example 1: Submit Package for Analysis

```bash
curl -X POST https://packguard.dev/api/v1/analyze/ \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "purl": "pkg:pypi/requests@2.28.1",
    "priority": 0
  }'
```

**Response**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "status": "queued",
    "queue_position": 3,
    "status_url": "https://packguard.dev/api/v1/task/123/",
    "result_url": "https://packguard.dev/media/reports/pypi/requests/2.28.1.json",
    "message": "Analysis queued at position 3"
  }
}
```

### Example 2: Check Task Status

```bash
curl https://packguard.dev/api/v1/task/123/
```

**Response**:
```json
{
  "success": true,
  "data": {
    "task_id": 123,
    "status": "running",
    "started_at": "2024-01-15T10:35:00Z",
    "remaining_time_minutes": 25
  }
}
```

### Example 3: List Your Tasks

```bash
curl -X GET "https://packguard.dev/api/v1/reports/?page=1&page_size=20&status=completed" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

### Example 4: Get Queue Status

```bash
curl https://packguard.dev/api/v1/queue/status/
```

### Example 5: Idempotent Request

```bash
curl -X POST https://packguard.dev/api/v1/analyze/ \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: unique-request-id-12345" \
  -d '{
    "purl": "pkg:pypi/requests@2.28.1"
  }'
```

If you make the same request again with the same idempotency key, you'll get the same task ID back.

### Example 6: Python Client

```python
import requests

API_BASE_URL = "https://packguard.dev/api/v1"
API_KEY = "YOUR_API_KEY"

headers = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

# Submit analysis
response = requests.post(
    f"{API_BASE_URL}/analyze/",
    headers=headers,
    json={"purl": "pkg:pypi/requests@2.28.1"}
)
task_data = response.json()
task_id = task_data["data"]["task_id"]

# Check status
status_response = requests.get(f"{API_BASE_URL}/task/{task_id}/")
status = status_response.json()
print(f"Task status: {status['data']['status']}")

# Wait for completion
import time
while status["data"]["status"] in ["queued", "running"]:
    time.sleep(10)
    status_response = requests.get(f"{API_BASE_URL}/task/{task_id}/")
    status = status_response.json()

# Download result
if status["data"]["status"] == "completed":
    download_url = status["data"]["download_url"]
    report = requests.get(download_url).json()
    print("Analysis complete!")
```

---

## Queue System

### Overview

The API uses a queue system to manage analysis tasks. Only one analysis container runs at a time to prevent resource conflicts.

### Task Status Flow

1. **pending**: Task created but not yet queued
2. **queued**: Task added to queue, waiting for processing
3. **running**: Task currently being processed by container
4. **completed**: Task finished successfully
5. **failed**: Task failed with error

### Priority System

Tasks can be assigned priority levels:
- **0**: Normal priority (default)
- **1-9**: Higher priority (processed first)
- **Negative**: Lower priority (processed last)

Tasks are processed in order of:
1. Priority (higher first)
2. Queue position (earlier first)

### Smart Caching

The system implements intelligent caching:
- Completed results are cached indefinitely
- Multiple requests for the same PURL return the same cached result
- No re-analysis is performed if a completed result exists

### Timeout Management

- Default timeout: 30 minutes per task
- Automatic monitoring: Background worker checks every 5 seconds
- Container cleanup: Timed out containers are automatically stopped
- Queue continuation: After timeout, the queue continues with the next task

---

## Report Structure

### Report File Location

Reports are saved in the following structure:
```
media/reports/{ecosystem}/{package_name}/{version}.json
```

Example:
```
media/reports/pypi/requests/2.28.1.json
```

### Report Metadata

Each report includes metadata:

```json
{
  "metadata": {
    "created_at": "2024-01-15T10:50:00Z",
    "package": {
      "name": "requests",
      "version": "2.28.1",
      "ecosystem": "pypi",
      "purl": "pkg:pypi/requests@2.28.1"
    },
    "analysis": {
      "status": "completed",
      "started_at": "2024-01-15T10:35:00Z",
      "completed_at": "2024-01-15T10:50:00Z",
      "duration_seconds": 900
    },
    "api": {
      "version": "1.0",
      "endpoint": "analyze_api",
      "generated_by": "Pack-a-mal Analysis Platform"
    }
  },
  "analysis_results": {
    // Analysis results here
  }
}
```

---

## Additional Endpoints

### Package Discovery Endpoints

These endpoints help discover available packages and versions:

- `GET /get_pypi_packages/` - List PyPI packages
- `GET /get_pypi_versions/?package_name=<name>` - Get versions for a PyPI package
- `GET /get_npm_packages/` - List npm packages
- `GET /get_npm_versions/?package_name=<name>` - Get versions for an npm package
- `GET /get_packagist_packages/` - List Packagist packages
- `GET /get_packagist_versions/?package_name=<name>` - Get versions for a Packagist package
- `GET /get_rubygems_packages/` - List RubyGems packages
- `GET /get_rubygems_versions/?package_name=<name>` - Get versions for a RubyGem package
- `GET /get_maven_packages/` - List Maven packages
- `GET /get_rust_packages/` - List Rust packages
- `GET /get_wolfi_packages/` - List Wolfi packages

These endpoints return JSON responses with package/version information.

---

## Support

For issues, questions, or feature requests, please contact the development team or refer to the project repository.

---

**Last Updated**: 2024-01-15
**API Version**: 1.0

