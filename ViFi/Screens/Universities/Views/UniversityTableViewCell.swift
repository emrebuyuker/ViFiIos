//
//  UniversityTableViewCell.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit

class UniversityTableViewCell: UITableViewCell {
    
    // MARK - Outles
    @IBOutlet weak var universityLabel: UILabel!
    
    // MARK - View Life Cycle
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    // MARK - Helpers Methods
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
