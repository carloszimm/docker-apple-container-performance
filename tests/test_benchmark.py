#!/usr/bin/env python3
"""
Tests for the Docker Desktop vs Apple container benchmark
"""

import unittest
import os
import sys
import subprocess
from pathlib import Path

# Add src to the path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

class TestBenchmarkSetup(unittest.TestCase):
    """Benchmark setup tests"""
    
    def test_venv_exists(self):
        """Test that the virtual environment exists"""
        venv_path = Path(__file__).parent.parent / "venv"
        self.assertTrue(venv_path.exists(), "Virtual environment not found")
    
    def test_config_exists(self):
        """Test that the configuration file exists"""
        config_path = Path(__file__).parent.parent / "config" / "experiment_config.yaml"
        self.assertTrue(config_path.exists(), "Configuration file not found")
    
    def test_benchmark_scripts_exist(self):
        """Test that the benchmark scripts exist"""
        scripts_dir = Path(__file__).parent.parent / "src" / "benchmarks"
        self.assertTrue(scripts_dir.exists(), "Scripts directory not found")
        
        required_scripts = [
            "run_experiment.sh",
            "run_startup_performance.sh",
            "run_cpu_performance.sh",
            "run_memory_performance.sh",
            "run_http_performance.sh",
            "run_disk_performance.sh",
            "run_stream_performance.sh",
            "run_math_performance.sh"
        ]
        
        for script in required_scripts:
            script_path = scripts_dir / script
            self.assertTrue(script_path.exists(), f"Script {script} not found")
    
    def test_analysis_scripts_exist(self):
        """Test that the analysis scripts exist"""
        analysis_dir = Path(__file__).parent.parent / "src" / "analysis"
        self.assertTrue(analysis_dir.exists(), "Analysis directory not found")
        
        required_scripts = [
            "analyze_results_enhanced.py"
        ]
        
        for script in required_scripts:
            script_path = analysis_dir / script
            self.assertTrue(script_path.exists(), f"Script {script} not found")
    
    def test_utils_scripts_exist(self):
        """Test that the utility scripts exist"""
        utils_dir = Path(__file__).parent.parent / "src" / "utils"
        self.assertTrue(utils_dir.exists(), "Utilities directory not found")

        required_scripts = [
            "benchmark_utils.sh",
            "check_rosetta.sh",
            "verify_experiment_requirements.sh",
            "collect_system_info.sh",
            "statistical_utils.sh",
        ]

        for script in required_scripts:
            script_path = utils_dir / script
            self.assertTrue(script_path.exists(), f"Script {script} not found")

class TestSystemDependencies(unittest.TestCase):
    """System dependency tests"""
    
    def test_docker_available(self):
        """Test that Docker is available"""
        try:
            result = subprocess.run(["docker", "--version"], 
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, "Docker is not available")
        except (subprocess.TimeoutExpired, FileNotFoundError):
            self.fail("Docker is not installed or not on PATH")
    
    def test_apple_container_available(self):
        """Test that Apple container is available"""
        try:
            result = subprocess.run(["container", "--version"], 
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, "Apple container is not available")
        except (subprocess.TimeoutExpired, FileNotFoundError):
            self.fail("Apple container is not installed or not on PATH")
    
    def test_benchmark_tools_available(self):
        """Test that the benchmark tools used by the scripts are available"""
        # sysbench, wrk, jq, bc are used by the run_*.sh scripts; hyperfine is not used
        tools = ["sysbench", "wrk", "jq", "bc"]

        for tool in tools:
            try:
                result = subprocess.run([tool, "--version"], 
                                      capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, f"Tool {tool} is not available")
            except (subprocess.TimeoutExpired, FileNotFoundError):
                self.fail(f"Tool {tool} is not installed or not on PATH")

class TestDataStructure(unittest.TestCase):
    """Data structure tests"""
    
    def test_data_directories_exist(self):
        """Test that the data directories exist"""
        base_path = Path(__file__).parent.parent

        required_dirs = [
            "bench_results",
        ]

        for dir_path in required_dirs:
            full_path = base_path / dir_path
            self.assertTrue(full_path.exists(),
                          f"Directory {dir_path} not found")

    def test_docs_directories_exist(self):
        """Test that the documentation directories exist"""
        base_path = Path(__file__).parent.parent

        required_dirs = [
            "docs/system_info",
        ]

        for dir_path in required_dirs:
            full_path = base_path / dir_path
            self.assertTrue(full_path.exists(), f"Directory {dir_path} not found")

if __name__ == "__main__":
    # Configure verbose output
    unittest.main(verbosity=2)
