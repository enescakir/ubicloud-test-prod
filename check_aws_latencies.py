import ping3
import statistics
from concurrent.futures import ThreadPoolExecutor, as_completed
import os

aws_endpoints = {
    'us-east-1': 'ec2.us-east-1.amazonaws.com',
    'us-east-2': 'ec2.us-east-2.amazonaws.com',
    'us-west-1': 'ec2.us-west-1.amazonaws.com',
    'us-west-2': 'ec2.us-west-2.amazonaws.com',
    'af-south-1': 'ec2.af-south-1.amazonaws.com',
    'ap-east-1': 'ec2.ap-east-1.amazonaws.com',
    'ap-south-1': 'ec2.ap-south-1.amazonaws.com',
    'ap-northeast-1': 'ec2.ap-northeast-1.amazonaws.com',
    'ap-northeast-2': 'ec2.ap-northeast-2.amazonaws.com',
    'ap-northeast-3': 'ec2.ap-northeast-3.amazonaws.com',
    'ap-southeast-1': 'ec2.ap-southeast-1.amazonaws.com',
    'ap-southeast-2': 'ec2.ap-southeast-2.amazonaws.com',
    'ca-central-1': 'ec2.ca-central-1.amazonaws.com',
    'eu-central-1': 'ec2.eu-central-1.amazonaws.com',
    'eu-west-1': 'ec2.eu-west-1.amazonaws.com',
    'eu-west-2': 'ec2.eu-west-2.amazonaws.com',
    'eu-west-3': 'ec2.eu-west-3.amazonaws.com',
    'eu-north-1': 'ec2.eu-north-1.amazonaws.com',
    'eu-south-1': 'ec2.eu-south-1.amazonaws.com',
    'me-south-1': 'ec2.me-south-1.amazonaws.com',
    'sa-east-1': 'ec2.sa-east-1.amazonaws.com',
    'us-gov-east-1': 'ec2.us-gov-east-1.amazonaws.com',
    'us-gov-west-1': 'ec2.us-gov-west-1.amazonaws.com'
}

def check_latency(endpoint, num_tests=10):
    latencies = []
    for _ in range(num_tests):
        try:
            latency = ping3.ping(endpoint)
            if latency is not None:
                latencies.append(latency * 1000)  # Convert to milliseconds
        except Exception as e:
            print(f"Error pinging {endpoint}: {e}")
    if latencies:
        return statistics.median(latencies)
    else:
        return "Request timed out"

num_tests = 10  # Number of tests to run for each endpoint

def check_region_latency(region, endpoint):
    p50_latency = check_latency(endpoint, num_tests)
    return region, endpoint, p50_latency

summary_lines = []

with ThreadPoolExecutor(max_workers=len(aws_endpoints)) as executor:
    futures = {executor.submit(check_region_latency, region, endpoint): region for region, endpoint in aws_endpoints.items()}
    for future in as_completed(futures):
        region, endpoint, p50_latency = future.result()
        if p50_latency == "Request timed out":
            output = "timed out"
            print(f"::warning::Latency test for {region} timed out.")
        else:
            output = f"{p50_latency:.2f} ms"

        summary_lines.append(f"| {region} | {output}|")
        print(f"{region:18} {output}")

# Write to GitHub Actions summary
summary_file = os.getenv('GITHUB_STEP_SUMMARY')
with open(summary_file, 'a') as f:
    f.write("# AWS Region Latency Test Results\n")
    f.write("| Region | p50 Latency |\n")
    f.write("| --- | --- |\n")
    for line in summary_lines:
        f.write(line + "\n")
