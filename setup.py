from setuptools import find_packages, setup


setup(
    name="noaa-navionics",
    version="0.1.0",
    description="Standard-library NOAA ENC downloader with CLI and Tkinter GUI",
    long_description="Standard-library NOAA ENC downloader with CLI and Tkinter GUI",
    license="MIT",
    author="Patrick Pragman",
    python_requires=">=3.9",
    package_dir={"": "src"},
    packages=find_packages("src"),
    install_requires=[],
    entry_points={
        "console_scripts": [
            "noaa-navionics=noaa_navionics.cli:main",
            "noaa-navionics-gui=noaa_navionics.gui:main",
            "noaa-navionics-status-gui=noaa_navionics.status_gui:main",
        ],
    },
)
