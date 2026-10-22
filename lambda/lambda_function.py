import os
import json
import time
import base64
import boto3
from botocore.exceptions import ClientError

s3_client = boto3.client('s3')

def lambda_handler(event, context):
    start_time = time.time()
    
    # Retrieve configuration strictly from environment variables (do not hardcode)
    bucket = os.environ.get('BUCKET')
    prefix = os.environ.get('PREFIX', '')
    if prefix and not prefix.endswith('/'):
        prefix += '/'

    # Resolve requested path from HTTP API / Function URL payload (v2.0 or v1.0)
    raw_path = event.get('rawPath') or event.get('path') or '/'
    clean_path = raw_path.split('?')[0]

    status_code = 200
    headers = {}
    is_base64 = False
    body = ""

    try:
        if clean_path in ['/', '/index.html']:
            s3_key = f"{prefix}index.html"
            response = s3_client.get_object(Bucket=bucket, Key=s3_key)
            html_content = response['Body'].read().decode('utf-8')
            
            # Replace placeholder with Lambda and function name
            fn_name = context.function_name if hasattr(context, 'function_name') else os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'LambdaFunction')
            html_content = html_content.replace('{{HOSTED_ON}}', f"Lambda {fn_name}")
            
            status_code = 200
            headers = {
                'Content-Type': 'text/html; charset=utf-8',
                'Cache-Control': 'max-age=60'
            }
            body = html_content

        elif clean_path == '/style.css':
            s3_key = f"{prefix}style.css"
            response = s3_client.get_object(Bucket=bucket, Key=s3_key)
            css_content = response['Body'].read().decode('utf-8')
            
            status_code = 200
            headers = {
                'Content-Type': 'text/css; charset=utf-8'
            }
            body = css_content

        elif clean_path == '/cv.pdf':
            s3_key = f"{prefix}cv.pdf"
            response = s3_client.get_object(Bucket=bucket, Key=s3_key)
            pdf_bytes = response['Body'].read()
            
            status_code = 200
            headers = {
                'Content-Type': 'application/pdf'
            }
            is_base64 = True
            body = base64.b64encode(pdf_bytes).decode('utf-8')

        else:
            # 404 for any unspecified route
            status_code = 404
            headers = {
                'Content-Type': 'text/html; charset=utf-8'
            }
            body = (
                "<!DOCTYPE html>"
                "<html lang=\"en\">"
                "<head><meta charset=\"UTF-8\"><title>404 Not Found</title></head>"
                "<body>"
                "<h1>404 Not Found</h1>"
                "<p>The requested resource could not be found on this server.</p>"
                "</body>"
                "</html>"
            )

    except ClientError as e:
        status_code = 404
        headers = {'Content-Type': 'text/html; charset=utf-8'}
        body = f"<!DOCTYPE html><html><body><h1>404 Not Found</h1><p>{str(e)}</p></body></html>"
    except Exception as e:
        status_code = 500
        headers = {'Content-Type': 'text/plain; charset=utf-8'}
        body = f"Internal Server Error: {str(e)}"

    elapsed_ms = round((time.time() - start_time) * 1000, 2)
    fn_name = context.function_name if hasattr(context, 'function_name') else 'cv-func'
    
    # Required structured JSON log entry: exactly {fn, path, status, ms}
    log_entry = {
        "fn": fn_name,
        "path": clean_path,
        "status": status_code,
        "ms": elapsed_ms
    }
    print(json.dumps(log_entry))

    response_payload = {
        "statusCode": status_code,
        "headers": headers,
        "body": body
    }
    if is_base64:
        response_payload["isBase64Encoded"] = True

    return response_payload
