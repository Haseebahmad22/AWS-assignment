# Lab 7 - Dual-Path Basic App Deployment on AWS

**Candidate:** Haseeb Ahmad  
**Roll Number:** 23L-3069  
**Email:** [l233069@lhr.nu.edu.pk](mailto:l233069@lhr.nu.edu.pk)  
**Course:** Cloud Computing (`cloud`)  

---

## 1. System Architecture

```
                                  +-----------------------+
                                  |     Internet User     |
                                  +-----------+-----------+
                                              |
                     +------------------------+------------------------+
                     |                                                 |
         [Path A: HTTP / Port 80]                         [Path B: HTTPS / Function URL]
                     |                                                 |
                     v                                                 v
        +-------------------------+                       +-------------------------+
        |   Amazon EC2 Instance   |                       |   AWS Lambda Function   |
        |   (Amazon Linux 2023)   |                       |     (Python 3.12)       |
        |  httpd Web Server :80   |                       |  Public Function URL    |
        |                         |                       |                         |
        |  Systemd Timer (5 min)  |                       |  Role: cv-lambda-role   |
        |  Role: cv-ec2-role      |                       +------------+------------+
        +------------+------------+                                    |
                     |                                                 |
                     |  aws s3 sync (IMDSv2)                           |  s3:GetObject
                     +------------------------+------------------------+
                                              |
                                              v
                                 +-------------------------+
                                 |    Private S3 Bucket    |
                                 |      cv-23l-3069        |
                                 |-------------------------|
                                 |  • site/index.html      |
                                 |  • site/style.css       |
                                 |  • site/cv.pdf          |
                                 |                         |
                                 | [Block Public Access ON]|
                                 | [Versioning: Enabled]   |
                                 +-------------------------+
```

### Request Flow Description
- **EC2 Path:** A client's HTTP request arrives at port 80 of the EC2 instance where the Apache web server directly serves the local static files, which are continuously synchronized in the background from the private S3 bucket by a 5-minute systemd timer script that dynamically replaces the footer placeholder with the EC2 instance ID via IMDSv2.
- **Lambda Path:** An HTTPS request hits the public Lambda Function URL, which invokes the Python 3.12 serverless handler that fetches the requested asset on-demand from the private S3 bucket using role-assumed STS credentials, injects the function name into the HTML or base64-encodes binary PDFs, and returns the response with structured JSON latency logging.

---

## 2. Access Denied Verification (Section 4)

Attempting to delete or overwrite an object from within the EC2 instance shell confirms least-privilege IAM boundary enforcement:

```console
[ec2-user@cv-ec2-23l-3069 ~]$ aws s3 rm s3://cv-23l-3069/site/index.html
delete failed: s3://cv-23l-3069/site/index.html An error occurred (AccessDenied) when calling the DeleteObject operation: Access Denied

[ec2-user@cv-ec2-23l-3069 ~]$ aws s3 cp /etc/hosts s3://cv-23l-3069/site/test.txt
upload failed: ../../../etc/hosts to s3://cv-23l-3069/site/test.txt An error occurred (AccessDenied) when calling the PutObject operation: Access Denied
```

---

## 3. EC2 Sync Logs (`/var/log/cv-sync.log`)

Last 10 lines showing scheduled 5-minute runs:

```log
2026-10-22T11:05:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:10:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:15:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:20:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:25:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:30:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:35:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:40:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:45:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
2026-10-22T11:50:01Z - SUCCESS: Synced s3://cv-23l-3069/site/ to /var/www/html. Configured EC2 i-0b04e3da40aafdd55
```

---

## 4. Written Questions & Answers

### 1. Why do the instance and the function use roles instead of access keys? What could go wrong if the keys were in the user data?
IAM roles issue temporary, automatically rotated security credentials via AWS STS directly to compute resources without hardcoding long-term credentials. If permanent access keys were embedded in user data or application source code, they could be exfiltrated through instance metadata queries (`curl http://169.254.169.254/latest/user-data`), git commits, or shell history. Leaked keys grant unauthorized external actors persistent access to AWS account resources until manually detected and revoked. IAM roles eliminate this risk by scoping credentials solely to the instance boundary with short lifespans.

### 2. Someone pastes the S3 address of index.html into a browser. What do they see, and which setting causes that?
The visitor sees an XML error page displaying HTTP status `403 Forbidden` with the error code `AccessDenied`. This behavior is enforced by Amazon S3 **Block Public Access**, which has all four public blocking settings enabled at the bucket level. Additionally, the bucket maintains no public bucket policy or ACL granting anonymous `s3:GetObject` permissions. Because the bucket is entirely private, anonymous direct HTTP requests from browsers are rejected by default.

### 3. Explain in your own words the permission on the function URL that lets anyone call it. Why is that acceptable for the function but not for the bucket?
The Lambda Function URL attaches a resource-based permission allowing the action `lambda:InvokeFunctionUrl` with `Principal: *` and `AuthType: NONE`, permitting unauthenticated callers to invoke the function endpoint. This is acceptable for the function because it acts as an intelligent application layer that strictly enforces business logic, restricts routes, applies cache headers, and sanitizes outgoing responses. Conversely, granting public access directly to the S3 bucket exposes raw storage objects without authorization controls, risks unauthorized file enumeration or scraping, and causes uncontrolled data egress billing.

### 4. Compare the two paths. What do you pay for when nobody visits the site? What happens if the traffic grows a hundred times?
When traffic is zero, the EC2 path continues to accrue standard per-hour compute and EBS volume storage charges regardless of utilization, while the serverless Lambda path incurs zero compute cost. If traffic suddenly surges a hundredfold, the single EC2 instance will saturate its fixed CPU and network capacity, causing high latency, queue buildup, or dropped connections unless manually scaled with an Auto Scaling Group and Load Balancer. In contrast, AWS Lambda automatically scales horizontally by instantiating parallel execution environments to absorb traffic spikes seamlessly, billing only for the exact invocation counts and compute time consumed.

### 5. You delete the EC2 instance. What do you lose and what do you still have?
Deleting the EC2 instance permanently destroys the instance's virtual machine compute state, its ephemeral files, its attached EBS root volume and local `/var/log/cv-sync.log` history, and its allocated public IPv4 address. However, you retain the complete set of authoritative CV source files in the durable S3 bucket (`site/index.html`, `style.css`, `cv.pdf`), both IAM roles and instance profiles, and the fully functioning Lambda serverless infrastructure. As a result, the CV website remains operational and publicly accessible via the Lambda Function URL without interruption.

---

## 5. Repository Structure
```text
README.md
collect-evidence.sh
evidence.txt
site/
  ├── index.html
  ├── style.css
  └── cv.pdf
ec2/
  ├── user-data.sh
  └── sync-cv.sh
lambda/
  └── lambda_function.py
iam/
  ├── ec2-trust-policy.json
  ├── ec2-permission-policy.json
  ├── lambda-trust-policy.json
  └── lambda-permission-policy.json
```
