import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
from sklearn.model_selection import train_test_split
from sklearn.tree import DecisionTreeClassifier
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, ConfusionMatrixDisplay
from sklearn.tree import plot_tree
import io
import os
import sys

def load_data():
    """
    Loads all the necessary csv files and returns them as pandas dataframes.
    """
    users_df = pd.read_csv('users.csv')
    billing_df = pd.read_csv('billing.csv')
    sessions_df = pd.read_csv('sessions.csv')
    events_df = pd.read_csv('events.csv')
    return users_df, billing_df, sessions_df, events_df

def bill_agregate(billing_df):
    return billing_df.groupby('user_id').agg(
            avg_mrr=('mrr', 'mean'),
            avg_active_seats=('active_seats', 'mean'),
            total_invoices_overdue=('invoices_overdue', 'sum'),
            total_discounts_applied=('discount_applied', 'sum'),
            total_support_tickets=('support_ticket_count', 'sum')
        ).reset_index()

def session_aggregate(sessions_df):
    return sessions_df.groupby('user_id').agg(
        avg_session_length_sec=('session_length_sec', 'mean'),
        total_sessions=('session_id', 'count')
    ).reset_index()