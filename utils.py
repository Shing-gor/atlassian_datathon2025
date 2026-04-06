"""
utils.py — Shared data loading and feature engineering helpers.

Provides reusable functions for loading raw CSVs and aggregating
billing, session, and event data into user-level feature tables
used across all analysis notebooks.
"""

import pandas as pd
import matplotlib.pyplot as plt
from typing import Union, Optional
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (
    classification_report,
    confusion_matrix,
    ConfusionMatrixDisplay,
)


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_data() -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """
    Load all four raw CSV datasets from the project root directory.

    Returns
    -------
    tuple of (users_df, billing_df, sessions_df, events_df)
        users_df    : User attributes — plan tier, industry, acquisition channel,
                      signup date, churn and upgrade flags.
        billing_df  : Monthly billing records — MRR, seat counts, invoices,
                      discounts, and support ticket counts.
        sessions_df : Session-level engagement logs — session id, length,
                      and session date per user.
        events_df   : In-product feature event logs — event type, user id,
                      and event timestamp.

    Raises
    ------
    FileNotFoundError
        If any expected CSV file is missing from the working directory.
    """
    DATA_DIR = "./data"

    files = {
        "users.csv"   : "users",
        "billing.csv" : "billing",
        "sessions.csv": "sessions",
        "events.csv"  : "events",
    }

    dataframes: dict[str, pd.DataFrame] = {}
    for filename, key in files.items():
        filepath = f"{DATA_DIR}/{filename}"
        try:
            dataframes[key] = pd.read_csv(filepath)
        except FileNotFoundError:
            raise FileNotFoundError(
                f"Expected data file '{filepath}' not found. "
                "Ensure all CSV files are present in the ./data directory."
            )

    return (
        dataframes["users"],
        dataframes["billing"],
        dataframes["sessions"],
        dataframes["events"],
    )


# ---------------------------------------------------------------------------
# Feature aggregation
# ---------------------------------------------------------------------------

def aggregate_billing(billing_df: pd.DataFrame) -> pd.DataFrame:
    """
    Aggregate monthly billing records to one row per user.

    Computes user-level billing signals that serve as features in the churn
    and upgrade models. Overdue invoices and support ticket counts are
    particularly strong leading indicators of churn risk.

    Parameters
    ----------
    billing_df : pd.DataFrame
        Raw billing table. Expected columns: user_id, mrr, active_seats,
        invoices_overdue, discount_applied, support_ticket_count.

    Returns
    -------
    pd.DataFrame
        One row per user_id with columns:
        - avg_mrr                  : Mean monthly recurring revenue across all months.
        - avg_active_seats         : Mean active seat count (proxy for team adoption depth).
        - total_invoices_overdue   : Cumulative overdue invoices (churn leading indicator).
        - total_discounts_applied  : Cumulative discounts applied (retention spend signal).
        - total_support_tickets    : Cumulative support tickets (product-fit satisfaction signal).
    """
    return (
        billing_df
        .groupby("user_id")
        .agg(
            avg_mrr                =("mrr",                 "mean"),
            avg_active_seats       =("active_seats",        "mean"),
            total_invoices_overdue =("invoices_overdue",    "sum"),
            total_discounts_applied=("discount_applied",    "sum"),
            total_support_tickets  =("support_ticket_count","sum"),
        )
        .reset_index()
    )


def aggregate_sessions(sessions_df: pd.DataFrame) -> pd.DataFrame:
    """
    Aggregate session logs to one row per user.

    Session frequency and average length are key behavioural engagement
    signals. Users with declining session frequency in months 4–6 post-signup
    show significantly higher churn probability in EDA.

    Parameters
    ----------
    sessions_df : pd.DataFrame
        Raw sessions table. Expected columns: user_id, session_id, session_length_sec.

    Returns
    -------
    pd.DataFrame
        One row per user_id with columns:
        - avg_session_length_sec : Mean session duration in seconds.
        - total_sessions         : Total number of recorded sessions.
    """
    return (
        sessions_df
        .groupby("user_id")
        .agg(
            avg_session_length_sec=("session_length_sec", "mean"),
            total_sessions        =("session_id",         "count"),
        )
        .reset_index()
    )


def aggregate_events(events_df: pd.DataFrame) -> pd.DataFrame:
    """
    Aggregate product event logs to one row per user.

    Feature breadth — the number of distinct in-product event types a user
    triggers — is a strong proxy for adoption depth. Users engaging with more
    features are significantly less likely to churn and more likely to upgrade.

    Parameters
    ----------
    events_df : pd.DataFrame
        Raw events table. Expected columns: user_id, event_type.

    Returns
    -------
    pd.DataFrame
        One row per user_id with columns:
        - total_events        : Total count of in-product events fired.
        - unique_event_types  : Number of distinct feature types used.
    """
    return (
        events_df
        .groupby("user_id")
        .agg(
            total_events      =("event_type", "count"),
            unique_event_types=("event_type", "nunique"),
        )
        .reset_index()
    )


# ---------------------------------------------------------------------------
# Full feature table builder
# ---------------------------------------------------------------------------

def build_feature_table(
    users_df: pd.DataFrame,
    billing_df: pd.DataFrame,
    sessions_df: pd.DataFrame,
    events_df: pd.DataFrame,
    target_col: str = "churned",
) -> pd.DataFrame:
    """
    Build the complete flat feature table used for ML modelling.

    Merges all aggregated feature sources into a single user-level DataFrame
    ready for train/test splitting. Categorical columns (plan, industry,
    acquisition_channel) are label-encoded. All nulls (users with no
    billing or session records) are filled with 0.

    Parameters
    ----------
    users_df    : Raw users DataFrame.
    billing_df  : Raw billing DataFrame.
    sessions_df : Raw sessions DataFrame.
    events_df   : Raw events DataFrame.
    target_col  : Column to use as the prediction target.
                  Either 'churned' (default) or 'upgraded'.

    Returns
    -------
    pd.DataFrame
        One row per user with all encoded features and the target column.
    """
    from sklearn.preprocessing import LabelEncoder

    billing_agg = aggregate_billing(billing_df)
    session_agg = aggregate_sessions(sessions_df)
    event_agg   = aggregate_events(events_df)

    le_plan     = LabelEncoder()
    le_industry = LabelEncoder()
    le_channel  = LabelEncoder()

    users_enc = users_df.copy()
    users_enc["plan_encoded"]     = le_plan.fit_transform(users_df["plan"])
    users_enc["industry_encoded"] = le_industry.fit_transform(users_df["industry"])
    users_enc["channel_encoded"]  = le_channel.fit_transform(users_df["acquisition_channel"])

    feature_df = (
        users_enc[[
            "user_id", target_col,
            "plan_encoded", "industry_encoded", "channel_encoded",
        ]]
        .merge(billing_agg, on="user_id", how="left")
        .merge(session_agg, on="user_id", how="left")
        .merge(event_agg,   on="user_id", how="left")
        .fillna(0)
    )

    return feature_df


# ---------------------------------------------------------------------------
# Model evaluation helper
# ---------------------------------------------------------------------------

def evaluate_model(
    model: RandomForestClassifier,
    X_test: pd.DataFrame,
    y_test: pd.Series,
    label_names: Optional[list] = None,
) -> None:
    """
    Print a classification report and display a confusion matrix for a fitted model.

    Intended as a quick, consistent evaluation helper across notebooks so
    that both the churn and upgrade models are assessed the same way.

    Parameters
    ----------
    model       : A fitted scikit-learn classifier.
    X_test      : Feature matrix for the held-out test set.
    y_test      : True target labels for the test set.
    label_names : Human-readable class names for the report output.
                  e.g. ["Retained", "Churned"] or ["Not upgraded", "Upgraded"].
    """
    y_pred = model.predict(X_test)

    print(classification_report(y_test, y_pred, target_names=label_names))

    cm   = confusion_matrix(y_test, y_pred)
    disp = ConfusionMatrixDisplay(cm, display_labels=label_names)

    fig, ax = plt.subplots(figsize=(5, 4))
    disp.plot(ax=ax, colorbar=False, cmap="Blues")
    ax.set_title("Confusion matrix")
    plt.tight_layout()
    plt.show()